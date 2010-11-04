#require "rexml/document"

class PersonController < ApplicationController

  def userinfo
    valid_http_methods :get, :put

    if !@http_user
      logger.debug "No user logged in, permission to userinfo denied"
      @errorcode = 401
      @summary = "No user logged in, permission to userinfo denied"
      render :template => 'error', :status => 401
      return
    end

    if request.get?
      with_watchlist = false
      if params[:login]
        login = URI.unescape( params[:login] )
        logger.debug "Generating for user from parameter #{login}"
        @render_user = User.find_by_login( login )
        if @render_user.blank?
          logger.debug "User is not valid!"
          render_error :status => 404, :errorcode => 'unknown_user',
            :message => "Unknown user: #{login}"
          return
        end
      else 
        logger.debug "Generating user info for logged in user #{@http_user.login}"
        @render_user = @http_user
      end
      if @http_user.is_admin? or @http_user == @render_user
        with_watchlist = true
      end
      render :text => @render_user.render_axml( with_watchlist ), :content_type => "text/xml"
    elsif request.put?
      user = @http_user
    
      if user 
        if params[:login]
          login = URI.unescape( params[:login] )
          user = User.find_by_login( login )
          if user and user.login != @http_user.login 
            unless @http_user.is_admin?
              logger.debug "User has no permission to change userinfo"
              render_error :status => 403, :errorcode => 'change_userinfo_no_permission',
                :message => "no permission to change userinfo for user #{user.login}"
              return
            end
          end
          if !user and @http_user.is_admin?
            user = User.create( 
                   :login => login,
                   :password => "notset",
                   :password_confirmation => "notset",
                   :email => "TEMP" )
            user.state = User.states["locked"]
          end
        end
      
        xml = REXML::Document.new( request.raw_post )

        logger.debug( "XML: #{request.raw_post}" )

        user.email = xml.elements["/person/email"].text
        user.realname = xml.elements["/person/realname"].text

        update_watchlist( user, xml )

        user.save!
        render_ok
      end
    end
  
  end

  def grouplist
    valid_http_methods :get

    if !@http_user
      logger.debug "No user logged in, permission to grouplist denied"
      @summary = "No user logged in, permission to grouplist denied"
      render :template => 'error', :status => 401
      return
    end
    unless params[:login]
      logger.debug "Missing account parameter for grouplist"
      @summary = "Missing account parameter for grouplist"
      render :template => 'error', :status => 404
      return
    end

    render :text => Group.render_group_list(params[:login]), :content_type => "text/xml"
  end

  def register
    valid_http_methods :post, :put

    if defined?( LDAP_MODE ) && LDAP_MODE == :on
      render_error :message => "LDAP mode enabled, users can only be registered via LDAP", :errorcode => "err_register_save", :status => 400
      return
    end

    xml = REXML::Document.new( request.raw_post )
    
    logger.debug( "register XML: #{request.raw_post}" )

    login = xml.elements["/unregisteredperson/login"].text
    logger.debug("Found login #{login}")
    realname = xml.elements["/unregisteredperson/realname"].text
    email = xml.elements["/unregisteredperson/email"].text
    password = xml.elements["/unregisteredperson/password"].text
    note = xml.elements["/unregisteredperson/note"].text
    status = "confirmed"

    unless @http_user and @http_user.is_admin?
      note = ""
    end

    if CONFIG['new_user_registration'] == "deny"
      unless @http_user and @http_user.is_admin?
        render_error :message => "User registration is disabled",
                     :errorcode => "err_register_save", :status => 400
        return
      end
    elsif CONFIG['new_user_registration'] == "confirmation"
      status = "unconfirmed"
    elsif CONFIG['new_user_registration'] and not CONFIG['new_user_registration'] == "allow"
      render_error :message => "Admin configured an unknown config option for new_user_registration",
                   :errorcode => "server_setup_error", :status => 500
      return
    end
    status = xml.elements["/unregisteredperson/state"].text if @http_user and @http_user.is_admin?

    if auth_method == :ichain
      if request.env['HTTP_X_USERNAME'].blank?
        render_error :message => "Missing iChain header", :errorcode => "err_register_save", :status => 400
        return
      end
      login = request.env['HTTP_X_USERNAME']
      email = request.env['HTTP_X_EMAIL'] unless request.env['HTTP_X_EMAIL'].blank?
      realname = request.env['HTTP_X_FIRSTNAME'] + " " + request.env['HTTP_X_LASTNAME'] unless request.env['HTTP_X_LASTNAME'].blank?
    end

    newuser = User.create( 
              :login => login,
              :password => password,
              :password_confirmation => password,
              :email => email )

    newuser.realname = realname
    newuser.state = User.states[status]
    newuser.adminnote = note
    logger.debug("Saving...")
    newuser.save
    
    if !newuser.errors.empty?
      details = newuser.errors.map{ |key, msg| "#{key}: #{msg}" }.join(", ")
      
      render_error :message => "Could not save the registration",
                   :errorcode => "err_register_save",
                   :details => details, :status => 400
    else
      # create subscription for submit requests
      if Object.const_defined? :Hermes
        h = Hermes.new
        h.add_user(login, email)
        h.add_request_subscription(login)
      end

      IchainNotifier.deliver_approval(newuser)
      render_ok
    end
  end
  
  def update_watchlist( user, xml )
    new_watchlist = []
    old_watchlist = []

    xml.elements.each("/person/watchlist/project") do |e|
      new_watchlist << e.attributes['name']
    end

    user.watched_projects.each do |wp|
      old_watchlist << wp.name
    end
    add_to_watchlist = new_watchlist.collect {|i| old_watchlist.include?(i) ? nil : i}.compact
    remove_from_watchlist = old_watchlist.collect {|i| new_watchlist.include?(i) ? nil : i}.compact

    remove_from_watchlist.each do |name|
      WatchedProject.find_by_name( name, :conditions => [ 'bs_user_id = ?', user.id ] ).destroy
    end

    add_to_watchlist.each do |name|
      user.watched_projects << WatchedProject.new( :name => name )
    end
    true
  end
  private :update_watchlist

  def change_my_password
    valid_http_methods :post, :put
    
    xml = REXML::Document.new( request.raw_post )

    logger.debug( "changepasswd XML: #{request.raw_post}" )

    login = xml.elements["/userchangepasswd/login"].text
    password = xml.elements["/userchangepasswd/password"].text

    if !@http_user
      logger.debug "No user logged in, permission to changing password denied"
      @errorcode = 401
      @summary = "No user logged in, permission to changing password denied"
      render :template => 'error', :status => 401
    else
      if not login or not password
        render_error :status => 404, :errorcode => 'failed to change password',
              :message => "Failed to change password: missing parameter"
        return
      end
      unless @http_user.is_admin? or login == @http_user.login
        render_error :status => 403, :errorcode => 'failed to change password',
              :message => "No sufficiend permissions to change password for others"
        return
      end
    end

    login = URI.unescape(login)
    newpassword = Base64.decode64(URI.unescape(password))
    
    #change password to LDAP if LDAP is enabled    
    if defined?( LDAP_MODE ) && LDAP_MODE == :on
      if defined?( LDAP_SSL ) && LDAP_SSL == :on
        require 'base64'
        begin
          logger.debug( "Using LDAP to change password for #{login}" )
          result = User.change_password_ldap(login, newpassword)
        rescue Exception
          logger.debug "LDAP_MODE selected but 'ruby-ldap' module not installed."
        end
        if result
          render_error :status => 404, :errorcode => 'change_passwd_failure', :message => "Failed to change password to ldap: #{result}"
          return
        end
      else
        render_error :status => 404, :errorcode => 'change_passwd_no_security', :message => "LDAP mode enabled, the user password can only be changed with LDAP_SSL enabling."
        return
      end
    end

    #update password in users db
    @user = User.find_by_login(login)
    if @user.blank?
      logger.debug "User is not valid!"
      render_error :status => 404, :errorcode => 'unknown_user',
        :message => "Unknown user: #{login}"
      return
    end
    logger.debug("find the user")
    @user.password = newpassword
    @user.password_confirmation = newpassword
    @user.state = User.states['confirmed']
    @user.save!
    render_ok
  end
end
