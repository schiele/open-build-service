require 'opensuse/backend'

class DbProject < ActiveRecord::Base
  include FlagHelper

  class CycleError < Exception; end
  class DeleteError < Exception; end
  class ReadAccessError < Exception; end
  class UnknownObjectError < Exception; end

  before_destroy :cleanup_before_destroy?

  has_many :project_user_role_relationships, :dependent => :destroy
  has_many :project_group_role_relationships, :dependent => :destroy
  has_many :db_packages, :dependent => :destroy
  has_many :attribs, :dependent => :destroy
  has_many :repositories, :dependent => :destroy
  has_many :messages, :as => :object, :dependent => :destroy

  has_many :develpackages, :class_name => "DbPackage", :foreign_key => 'develproject_id'
  has_many :linkedprojects, :order => :position, :class_name => "LinkedProject", :foreign_key => 'db_project_id'

  has_many :taggings, :as => :taggable, :dependent => :destroy
  has_many :tags, :through => :taggings

  has_many :download_stats
  has_many :downloads, :dependent => :destroy
  has_many :ratings, :as => :object, :dependent => :destroy

  has_many :flags, :dependent => :destroy

  has_one :db_project_type

  # optional
  has_one :maintenance_incident, :dependent => :destroy

  # self-reference between devel projects and maintenance projects
  has_many :maintained_projects, :class_name => "DbProject", :foreign_key => "maintenance_project_id"
  belongs_to :maintenance_project, :class_name => "DbProject"

  has_many  :develprojects, :class_name => "DbProject", :foreign_key => 'develproject_id'
  belongs_to :develproject, :class_name => "DbProject"

  attr_accessible :name, :title, :description

  def download_name
    self.name.gsub(/:/, ':/')
  end
  
  def destroy
    # basically empty, but needed here to get the cleanup_before_destroy? method called
    super
  end

  def cleanup_before_destroy?
    # find linking repositories
    lreps = Array.new
    self.repositories.each do |repo|
      repo.linking_repositories.each do |lrep|
        lreps << lrep
      end
    end
    if lreps.length > 0
      #replace links to this projects with links to the "deleted" project
      del_repo = DbProject.find_by_name("deleted").repositories[0]
      lreps.each do |link_rep|
        link_rep.path_elements.find(:all, :include => ["link"]).each do |pe|
          next unless Repository.find_by_id(pe.repository_id).db_project_id == self.id
          pe.link = del_repo
          pe.save
          #update backend
          link_prj = link_rep.db_project
          logger.info "updating project '#{link_prj.name}'"
          Suse::Backend.put_source "/source/#{link_prj.name}/_meta", link_prj.to_axml
        end
      end
    end
    # deleting local devel packages
    self.db_packages.each do |pkg|
      if pkg.develpackage_id
        pkg.develpackage_id = nil
        pkg.save
      end
      if pkg.develproject_id
        pkg.develproject_id = nil
        pkg.save
      end
    end
  end

#  def before_validation
#  def after_create
#    raise ReadAccessError.new "Unknown project" unless DbProject.check_access?(self)
#  end

  class << self

    def is_remote_project?(name, skip_access=false)
      lpro, rpro = find_remote_project(name, skip_access)
      !lpro.nil? and !lpro.remoteurl.nil?
    end

    def is_hidden?(name)
      options = {:conditions => ["name = BINARY ?", name]}
      validate_find_options(options)
      set_readonly_option!(options)

      dbp = find_initial(options)
      return nil if dbp.nil?
      rels = dbp.flags.count :conditions => 
          ["db_project_id = ? and flag = 'access' and status = 'disable'", dbp.id]
      return true if rels > 0
      return false
    end


    def check_access?(dbp=self)
      return false if dbp.nil?
      # check for 'access' flag

      # same cache as in public controller
      key = "public_project:" + dbp.name
      public_allowed = Rails.cache.fetch(key, :expires_in => 30.minutes) do
        flags_set = dbp.flags.count :conditions => 
            ["db_project_id = ? and flag = 'access' and status = 'disable'", dbp.id]
        flags_set == 0
      end

      # Do we need a per user check ?
      return true if public_allowed
      return true if User.currentAdmin

      # simple check for involvement --> involved users can access
      # dbp.id, User.currentID
      grouprels_exist = dbp.project_group_role_relationships.count :conditions => ["db_project_id = ?" , dbp.id]

      if grouprels_exist > 0
        # fetch project groups
        grouprels = dbp.project_group_role_relationships.find(:all, :conditions => ["db_project_id = ?", dbp.id])
        ret = 0
        grouprels.each do |grouprel|
          # check if User.currentID belongs to group
          us = User.find(User.currentID)
          if grouprel and grouprel.bs_group_id
            # LOCAL
            # if user is in group -> return true
            ret = ret + 1 if us.is_in_group?(grouprel.bs_group_id)
            # LDAP
# FIXME: please do not do special things here for ldap. please cover this in a generic group modell.
            if defined?( LDAP_MODE ) && LDAP_MODE == :on
              if defined?( LDAP_GROUP_SUPPORT ) && LDAP_GROUP_SUPPORT == :on
                if us.user_in_group_ldap?(User.currentID, group.bs_group_id)
                  ret = ret + 1
                end
              end
            end
            #
          end
        end
        # relationship to package -> access
        return true if ret > 0
      end

      userrels = dbp.project_user_role_relationships.count :first, :conditions => ["db_project_id = ? and bs_user_id = ?", dbp.id, User.currentID], :include => :role
      if userrels > 0 
        # relationship to package -> access
        return true
      end
      # no relationship to package -> no access
      return false
    end

    # own version of find
    def find(*args)
      options = args.extract_options!
      validate_find_options(options)
      set_readonly_option!(options)

      def securedfind_byids(args,options)
        dbp=find_from_ids(args,options)
        return if dbp.nil?
        return unless check_access?(dbp)
        return dbp
      end

      def securedfind_every(options)
        unless User.currentAdmin
          # limit to projects which have no "access" flag, except user has any role inside
          # FIXME3.0: we should limit this to maintainer and reader role only ?
          #            
          options[:joins] = "" if options[:joins].nil?
          options[:joins] += " LEFT JOIN flags f ON f.db_project_id = db_projects.id AND (ISNULL(f.flag) OR flag = 'access')" # filter projects with or without access flag
          options[:joins] += " LEFT OUTER JOIN project_user_role_relationships ur ON ur.db_project_id = db_projects.id"
          options[:group] = "db_projects.id" unless options[:group] # is creating a DISTINCT select to have uniq results

          cond = "((f.flag = 'access' AND ur.bs_user_id = #{User.current ? User.currentID : User.nobodyID}) OR ISNULL(f.flag))"
          if options[:conditions].nil?
            options[:conditions] = cond
          else
            if options[:conditions].class == String
              options[:conditions] = options[:conditions] # TDWTF ?!?
            elsif options[:conditions].class == Hash
              wacky = ''
              options[:conditions].keys.each {|k| wacky += ' AND (' + k.to_s + ')'}
              options[:conditions] = cond + wacky
            else
              options[:conditions][0] = cond + "AND (" + options[:conditions][0] + ")"
            end
          end
        end
        return find_every(options)
      end

      def securedfind_last(options)
        dbp = find_last(options)
        return if dbp.nil?
        return unless check_access?(dbp)
        return dbp
      end

      def securedfind_initial(options)
        dbp = find_initial(options)
        return if dbp.nil?
        return unless check_access?(dbp)
        return dbp
      end

      case args.first
        when :first then securedfind_initial(options)
        when :last  then securedfind_last(options)
        when :all   then securedfind_every(options)
        else    securedfind_byids(args, options)
      end
    end
    
    # returns an object of project(local or remote) or raises an exception
    # should be always used when a project is required
    # The return value is either a DbProject for local project or an xml 
    # array for a remote project
    def get_by_name(name)
      dbp = find :first, :conditions => ["name = BINARY ?", name]
      if dbp.nil?
        dbp, remote_name = find_remote_project(name)
        return dbp.name + ":" + remote_name if dbp
        raise UnknownObjectError, name
      end
      unless check_access?(dbp)
        raise ReadAccessError, name
      end
      return dbp
    end

    # to check existens of a project (local or remote)
    def exists_by_name(name)
      dbp = find :first, :conditions => ["name = BINARY ?", name]
      if dbp.nil?
        return true if find_remote_project(name)
        return false
      end
      unless check_access?(dbp)
        return false
      end
      return true
    end

    # to be obsoleted, this function is not throwing exceptions on problems
    # use get_by_name or exists_by_name instead
    def find_by_name(name)
      dbp = find :first, :conditions => ["name = BINARY ?", name]
      return if dbp.nil?
      return unless check_access?(dbp)
      return dbp
    end


    def find_by_attribute_type( attrib_type )
      # One sql statement is faster than a ruby loop
      # attribute match in project
      sql =<<-END_SQL
      SELECT prj.*
      FROM db_projects prj
      LEFT OUTER JOIN attribs attrprj ON prj.id = attrprj.db_project_id
      WHERE attrprj.attrib_type_id = BINARY ?
      END_SQL

      sql += " GROUP by prj.id"
      ret = DbProject.find_by_sql [sql, attrib_type.id.to_s]
      return if ret.nil?
      return ret if User.currentAdmin
      ret.each do |dbp|
        ret.delete(dbp) unless check_access?(dbp)
      end
      return ret
    end

    def store_axml( project )
      dbp = nil
      DbProject.transaction do
        if !(dbp = DbProject.find_by_name(project.name))
          dbp = DbProject.new( :name => project.name.to_s )
        end
        dbp.store_axml( project )
      end
      return dbp
    end

    def find_remote_project(name, skip_access=false)
      return nil unless name
      fragments = name.split(/:/)
      local_project = String.new
      remote_project = nil

      while fragments.length > 1
        remote_project = [fragments.pop, remote_project].compact.join ":"
        local_project = fragments.join ":"
        logger.debug "checking local project #{local_project}, remote_project #{remote_project}"
        if skip_access
          # hmm calling a private class method is not the best idea..
          lpro = find_initial :conditions => ["name = BINARY ?", local_project]
        else
          lpro = DbProject.find_by_name local_project
        end
        return lpro, remote_project unless lpro.nil? or lpro.remoteurl.nil?
      end
      return nil
    end
  end

  def find_linking_projects
      sql =<<-END_SQL
      SELECT prj.*
      FROM db_projects prj
      LEFT OUTER JOIN linked_projects lp ON lp.db_project_id = prj.id
      LEFT OUTER JOIN db_projects lprj ON lprj.id = lp.linked_db_project_id
      WHERE lprj.name = BINARY ?
      END_SQL
      # ACL TODO: should be check this or do we break functionality ?
      result = DbProject.find_by_sql [sql, self.name]
  end

  def is_locked?
      return true if flags.find_by_flag_and_status "lock", "enable"
      return false
  end

  # NOTE: this is no permission check, should it be added ?
  def can_be_deleted?
    # check if other packages have me as devel project
    unless self.develpackages.empty?
      msg = "Unable to delete project #{self.name}; following packages use this project as develproject: "
      msg += self.develpackages.map {|pkg| pkg.db_project.name+"/"+pkg.name}.join(", ")
      raise DeleteError.new "project is used by following projects as devel project: #{msg}"
    end

    # check all packages, if any get refered as develpackage
    self.db_packages.each do |pkg|
      msg = ""
      pkg.develpackages.each do |dpkg|
        if self != dpkg.db_project
          msg += dpkg.db_project.name + "/" + dpkg.name + ", "
        end
      end
      unless msg == ""
        raise DeleteError.new "packages in this project are used by following packages as devel package: #{msg}"
      end
    end

    # do not allow to remove maintenance master projects if there are incident projects
    if self.project_type == "maintenance"
      if MaintenanceIncident.find_by_maintenance_db_project_id self.id
        raise DeleteError.new "This maintenance project has incident projects and can therefore not be deleted."
      end
    end

  end

  def store_axml( project, force=nil )
    DbProject.transaction do
      logger.debug "### name comparison: self.name -> #{self.name}, project_name -> #{project.name.to_s}"
      if self.name != project.name.to_s
        raise SaveError, "project name mismatch: #{self.name} != #{project.name}"
      end

      self.title = project.value(:title)
      self.description = project.value(:description)
      self.remoteurl = project.value(:remoteurl)
      self.remoteproject = project.value(:remoteproject)
      self.updated_at = Time.now
      kind = project.value(:kind) || "standard"
      project_type = DbProjectType.find_by_name(kind)
      raise SaveError, "unable to find project kind '#{kind}'" if project_type.nil?
      self.type_id = project_type.id
      self.save!

      #--- update linked projects ---#
      position = 1
      #destroy all current linked projects
      self.linkedprojects.destroy_all

      #recreate linked projects from xml
      project.each_link do |l|
        link = DbProject.find_by_name( l.project )
        if link.nil?
          if DbProject.find_remote_project(l.project)
            self.linkedprojects.create(
                :db_project => self,
                :linked_remote_project_name => l.project,
                :position => position
            )
          else
            raise SaveError, "unable to link against project '#{l.project}'"
          end
        else
          if link == self
            raise SaveError, "unable to link against myself"
          end
          self.linkedprojects.create(
              :db_project => self,
              :linked_db_project => link,
              :position => position
          )
        end
        position += 1
      end
      #--- end of linked projects update  ---#

      #--- devel project ---#
      self.develproject = nil
      if project.has_element? :devel
        if project.devel.has_attribute? 'project'
          prj_name = project.devel.project.to_s
          unless develprj = DbProject.get_by_name(prj_name)
            raise SaveError, "value of develproject has to be a existing project (project '#{prj_name}' does not exist)"
          end
          if develprj == self
            raise SaveError, "Devel project can not point to itself"
          end
          self.develproject = develprj

        end
      end
      #--- end devel project ---#
      # FIXME: it would be nicer to store only as needed
      self.updated_at = Time.now
      self.save!
      # cycle detection
      prj = self
      processed = {}
      while ( prj and prj.develproject )
        prj_name = prj.name
        # cycle detection
        if processed[prj_name]
          str = ""
          processed.keys.each do |key|
            str = str + " -- " + key
          end
          raise CycleError.new "There is a cycle in devel definition at #{str}"
          return nil
        end
        processed[prj_name] = 1
        prj = prj.develproject
      end

      #--- maintenance-related parts ---#
      # First remove all maintained project relations
      maintained_projects.each do |maintained_project|
        maintained_project.maintenance_project_id = nil
        maintained_project.save!
      end
      # Set this project as the maintenance project for all maintained projects found in the XML
      project.each("maintenance/maintains") do |maintains|
        maintained_project = DbProject.get_by_name(maintains.value('project'))
        maintained_project.maintenance_project_id = self.id
        maintained_project.save!
      end

      #--- update users ---#
      usercache = Hash.new
      self.project_user_role_relationships.each do |purr|
        h = usercache[purr.user.login] ||= Hash.new
        h[purr.role.title] = purr
      end

      project.each_person do |person|
        if usercache.has_key? person.userid
          # user has already a role in this project
          pcache = usercache[person.userid]
          if pcache.has_key? person.role
            #role already defined, only remove from cache
            pcache[person.role] = :keep
          else
            #new role
            if not Role.rolecache.has_key? person.role
              raise SaveError, "illegal role name '#{person.role}'"
            end

            ProjectUserRoleRelationship.create(
              :user => User.get_by_login(person.userid),
              :role => Role.rolecache[person.role],
              :db_project => self
            )
          end
        else
          if not Role.rolecache.has_key? person.role
            raise SaveError, "illegal role name '#{person.role}'"
          end

          user=User.get_by_login(person.userid)

          begin
            ProjectUserRoleRelationship.create(
              :user => user,
              :role => Role.rolecache[person.role],
              :db_project => self
            )
          rescue ActiveRecord::StatementInvalid => err
            if /^Mysql::Error: Duplicate entry/.match(err)
              logger.debug "user '#{person.userid}' already has the role '#{person.role}' in project '#{self.name}'"
            else
              raise err
            end
          end
        end
      end
      
      #delete all roles that weren't found in the uploaded xml
      usercache.each do |user, roles|
        roles.each do |role, object|
          next if object == :keep
          object.destroy
        end
      end

      #--- end update users ---#

      #--- update groups ---#
      groupcache = Hash.new
      self.project_group_role_relationships.each do |pgrr|
        h = groupcache[pgrr.group.title] ||= Hash.new
        h[pgrr.role.title] = pgrr
      end

      project.each_group do |ge|
        if groupcache.has_key? ge.groupid
          # group has already a role in this project
          pcache = groupcache[ge.groupid]
          if pcache.has_key? ge.role
            #role already defined, only remove from cache
            pcache[ge.role] = :keep
          else
            #new role
            if not Role.rolecache.has_key? ge.role
              raise SaveError, "illegal role name '#{ge.role}'"
            end

            ProjectGroupRoleRelationship.create(
              :group => Group.get_by_title(ge.groupid),
              :role => Role.rolecache[ge.role],
              :db_project => self
            )
          end
        else
          if not Role.rolecache.has_key? ge.role
            raise SaveError, "illegal role name '#{ge.role}'"
          end

          if !(group=Group.find_by_title(ge.groupid))
            # check with LDAP
            if defined?( LDAP_MODE ) && LDAP_MODE == :on
              if defined?( LDAP_GROUP_SUPPORT ) && LDAP_GROUP_SUPPORT == :on
                if User.find_group_with_ldap(ge.groupid)
                  logger.debug "Find and Create group '#{ge.groupid}' from LDAP"
                  newgroup = Group.create( :title => ge.groupid )
                  unless newgroup.errors.empty?
                    raise SaveError, "unknown group '#{ge.groupid}', failed to create the ldap groupid on OBS"
                  end
                  group=Group.find_by_title(ge.groupid)
                else
                  raise SaveError, "unknown group '#{ge.groupid}' on LDAP server"
                end
              end
            end

            unless group
              raise SaveError, "unknown group '#{ge.groupid}'"
            end
          end

          begin
            ProjectGroupRoleRelationship.create(
              :group => group,
              :role => Role.rolecache[ge.role],
              :db_project => self
            )
          rescue ActiveRecord::StatementInvalid => err
            if /^Mysql::Error: Duplicate entry/.match(err)
              logger.debug "group '#{ge.groupid}' already has the role '#{ge.role}' in project '#{self.name}'"
            else
              raise err
            end
          end
        end
      end
      
      #delete all roles that weren't found in the uploaded xml
      groupcache.each do |group, roles|
        roles.each do |role, object|
          next if object == :keep
          object.destroy
        end
      end
      #--- end update groups ---#

      #--- update flag group ---#
      update_all_flags( project )

      #--- update repository download settings ---#
      dlcache = Hash.new
      self.downloads.each do |dl|
        dlcache["#{dl.architecture.name}"] = dl
      end

      project.each_download do |dl|
        if dlcache.has_key? dl.arch.to_s
          logger.debug "modifying download element, arch: #{dl.arch.to_s}"
          cur = dlcache[dl.arch.to_s]
        else
          logger.debug "adding new download entry, arch #{dl.arch.to_s}"
          cur = self.downloads.create
          self.updated_at = Time.now
        end
        cur.metafile = dl.metafile.to_s
        cur.mtype = dl.mtype.to_s
        cur.baseurl = dl.baseurl.to_s
        raise SaveError, "unknown architecture" unless Architecture.archcache.has_key? dl.arch.to_s
        cur.architecture = Architecture.archcache[dl.arch.to_s]
        cur.save!
        dlcache.delete dl.arch.to_s
      end

      dlcache.each do |arch, object|
        logger.debug "remove download entry #{arch}"
        object.destroy
      end

      #--- update repositories ---#
      repocache = Hash.new
      self.repositories.each do |repo|
        repocache[repo.name] = repo unless repo.remote_project_name
      end

      project.each_repository do |repo|
        was_updated = false

        if not repocache.has_key? repo.name
          logger.debug "adding repository '#{repo.name}'"
          current_repo = self.repositories.create( :name => repo.name )
          was_updated = true
        else
          logger.debug "modifying repository '#{repo.name}'"
          current_repo = repocache[repo.name]
        end

        #--- repository flags ---#
        # check for rebuild configuration
        if not repo.has_attribute? :rebuild and current_repo.rebuild
          current_repo.rebuild = nil
          was_updated = true
        end
        if repo.has_attribute? :rebuild
          if repo.rebuild != current_repo.rebuild
            current_repo.rebuild = repo.rebuild
            was_updated = true
          end
        end
        # check for block configuration
        if not repo.has_attribute? :block and current_repo.block
          current_repo.block = nil
          was_updated = true
        end
        if repo.has_attribute? :block
          if repo.block != current_repo.block
            current_repo.block = repo.block
            was_updated = true
          end
        end
        # check for linkedbuild configuration
        if not repo.has_attribute? :linkedbuild and current_repo.linkedbuild
          current_repo.linkedbuild = nil
          was_updated = true
        end
        if repo.has_attribute? :linkedbuild
          if repo.linkedbuild != current_repo.linkedbuild
            current_repo.linkedbuild = repo.linkedbuild
            was_updated = true
          end
        end
        #--- end of repository flags ---#

        #destroy all current releasetargets
        current_repo.release_targets.each { |rt| rt.destroy }

        #recreate release targets from xml
        repo.each_releasetarget do |rt|
          target_repo = Repository.find_by_project_and_repo_name( rt.project, rt.repository )
          unless target_repo
            raise SaveError, "Unknown target repository '#{rt.project}/#{rt.repository}'"
          end
          unless target_repo.remote_project_name.nil?
            raise SaveError, "Can not use remote repository as release target '#{rt.project}/#{rt.repository}'"
          end
          trigger = nil
          if rt.has_attribute? :trigger and rt.trigger != "manual"
            if rt.trigger != "maintenance"
              # automatic triggers are only allowed inside the same project
              unless rt.project == project.name
                raise SaveError, "Automatic release updates are only allowed into a project to the same project"
              end
            end
            trigger = rt.trigger
          end
          current_repo.release_targets.create :target_repository => target_repo, :trigger => trigger
          was_updated = true
        end

        #set host hostsystem
        if repo.has_element? :hostsystem
          hostsystem = DbProject.get_by_name repo.hostsystem.project
          target_repo = hostsystem.repositories.find_by_name repo.hostsystem.repository
          unless target_repo
            raise SaveError, "Unknown target repository '#{repo.hostsystem.project}/#{repo.hostsystem.repository}'"
          end
          if target_repo != current_repo.hostsystem
            current_repo.hostsystem = target_repo
            was_updated = true
          end
        elsif current_repo.hostsystem
          current_repo.hostsystem = nil
          was_updated = true
        end

        #destroy all current pathelements
        current_repo.path_elements.each { |pe| pe.destroy }

        #recreate pathelements from xml
        position = 1
        repo.each_path do |path|
          link_repo = Repository.find_by_project_and_repo_name( path.project, path.repository )
          if path.project == self.name and path.repository == repo.name
            raise SaveError, "Using same repository as path element is not allowed"
          end
          unless link_repo
            raise SaveError, "unable to walk on path '#{path.project}/#{path.repository}'"
          end
          current_repo.path_elements.create :link => link_repo, :position => position
          position += 1
          was_updated = true
        end

        was_updated = true if current_repo.architectures.size > 0 or repo.each_arch.size > 0

        if was_updated
          current_repo.save!
          self.updated_at = Time.now
        end

        #destroy architecture references
        current_repo.architectures.clear

        repo.each_arch do |arch|
          unless Architecture.archcache.has_key? arch.text
            raise SaveError, "unknown architecture: '#{arch}'"
          end
          current_repo.architectures << Architecture.archcache[arch.text]
          was_updated = true
        end

        repocache.delete repo.name
      end

      # delete remaining repositories in repocache
      repocache.each do |name, object|
        #find repositories that link against this one and issue warning if found
        list = PathElement.find( :all, :conditions => ["repository_id = ?", object.id] )
        unless list.empty?
          logger.debug "offending repo: #{object.inspect}"
          if force
            #replace links to the repository with links to the "deleted" project repository
            del_repo = DbProject.find_by_name("deleted").repositories[0]
            list.each do |pe|
              pe.link = del_repo
              pe.save
              #update backend
              link_prj = link_rep.db_project
              logger.info "updating project '#{link_prj.name}'"
              Suse::Backend.put_source "/source/#{link_prj.name}/_meta", link_prj.to_axml
            end
          else
            linking_repos = list.map {|x| x.repository.db_project.name+"/"+x.repository.name}.join "\n"
            raise SaveError, "Repository #{self.name}/#{name} cannot be deleted because following repos link against it:\n"+linking_repos
          end
        end
        logger.debug "deleting repository '#{name}'"
        self.repositories.delete object
        object.destroy
        self.updated_at = Time.now
      end
      repocache = nil
      #--- end update repositories ---#
      
      store

    end #transaction
  end

  def store(opt={})
    # update timestamp and save
    self.save!
    # expire cache
    Rails.cache.delete('meta_project_%d' % id)

    if write_through?
      login = User.current.login unless opt[:login] # Allow to override if User.current isn't available yet
      path = "/source/#{self.name}/_meta?user=#{CGI.escape(login)}"
      path += "&comment=#{CGI.escape(opt[:comment])}" unless opt[:comment].blank?
      path += "&lowprio=1" if opt[:lowprio]
      Suse::Backend.put_source( path, to_axml )
    end

    # FIXME: store attributes also to backend 
  end

  def store_attribute_axml( attrib, binary=nil )

    raise SaveError, "attribute type without a namespace " if not attrib.namespace
    raise SaveError, "attribute type without a name " if not attrib.name

    # check attribute type
    if ( not atype = AttribType.find_by_namespace_and_name(attrib.namespace, attrib.name) or atype.blank? )
      raise SaveError, "unknown attribute type '#{attrib.namespace}:#{attrib.name}'"
    end
    # verify the number of allowed values
    if atype.value_count and attrib.has_element? :value and atype.value_count != attrib.each_value.length
      raise SaveError, "attribute '#{attrib.namespace}:#{attrib.name}' has #{attrib.each_value.length} values, but only #{atype.value_count} are allowed"
    end
    if atype.value_count and atype.value_count > 0 and not attrib.has_element? :value
      raise SaveError, "attribute '#{attrib.namespace}:#{attrib.name}' requires #{atype.value_count} values, but none given"
    end

    # verify with allowed values for this attribute definition
    if atype.allowed_values.length > 0
      logger.debug( "Verify value with allowed" )
      attrib.each_value.each do |value|
        found = 0
        atype.allowed_values.each do |allowed|
          if allowed.value == value.to_s
            found = 1
            break
          end
        end
        if found == 0
          raise SaveError, "attribute value #{value} for '#{attrib.name} is not allowed'"
        end
      end
    end
    # update or create attribute entry
    if a = find_attribute(attrib.namespace, attrib.name)
      a.update_from_xml(attrib)
    else
      # create the new attribute entry
      self.attribs.new(:attrib_type => atype).update_from_xml(attrib)
    end
  end

  def find_attribute( namespace, name, binary=nil )
    logger.debug "find_attribute for #{namespace}:#{name}"
    if namespace.nil?
      raise RuntimeError, "Namespace must be given"
    end
    if name.nil?
      raise RuntimeError, "Name must be given"
    end
    if binary
      raise RuntimeError, "binary packages are not allowed in project attributes"
    end
    return attribs.find(:first, :joins => "LEFT OUTER JOIN attrib_types at ON attribs.attrib_type_id = at.id LEFT OUTER JOIN attrib_namespaces an ON at.attrib_namespace_id = an.id", :conditions => ["at.name = BINARY ? and an.name = BINARY ? and ISNULL(attribs.binary)", name, namespace])
  end

  def render_issues_axml(params)
    builder = Builder::XmlMarkup.new( :indent => 2 )

    filter_changes = states = nil
    filter_changes = params[:changes].split(",") if params[:changes]
    states = params[:states].split(",") if params[:states]
    login = params[:login]

    xml = builder.project( :name => self.name ) do |project|
      self.db_packages.each do |pkg|
        project.package( :project => pkg.db_project.name, :name => pkg.name ) do |package|
          pkg.db_package_issues.each do |i|
            next if filter_changes and not filter_changes.include? i.change
            next if states and (not i.issue.state or not states.include? i.issue.state)
            o = nil
            if i.issue.owner_id
              # self.owner must not by used, since it is reserved by rails
              o = User.find_by_id i.issue.owner_id
            end
            next if login and (not o or not login == o.login)
            i.issue.render_body(package, i.change)
          end
        end
      end
    end

    xml
  end

  def render_attribute_axml(params)
    builder = Builder::XmlMarkup.new( :indent => 2 )

    done={};
    xml = builder.attributes() do |a|
      attribs.each do |attr|
        next if params[:name] and not attr.attrib_type.name == params[:name]
        next if params[:namespace] and not attr.attrib_type.attrib_namespace.name == params[:namespace]
        type_name = attr.attrib_type.attrib_namespace.name+":"+attr.attrib_type.name
        a.attribute(:name => attr.attrib_type.name, :namespace => attr.attrib_type.attrib_namespace.name) do |y|
          done[type_name]=1
          if attr.values.length>0
            attr.values.each do |val|
              y.value(val.value)
            end
          else
            if params[:with_default]
              attr.attrib_type.default_values.each do |val|
                y.value(val.value)
              end
            end
          end
        end
      end
    end
  end

  def write_through?
    conf = ActiveXML::Config
    conf.global_write_through && (conf::TransportMap.options_for(:project)[:write_through] != :false)
  end
  private :write_through?

  # step down through namespaces until a project is found, returns found project or nil
  def self.find_parent_for(project_name)
    name_parts = project_name.split(/:/)

    #project is not inside a namespace
    return nil if name_parts.length <= 1

    while name_parts.length > 1
      name_parts.pop
      if (p = DbProject.find_by_name name_parts.join(":"))
        #parent project found
        return p
      end
    end
    return nil
  end

  # convenience method for self.find_parent_for
  def find_parent
    self.class.find_parent_for self.name
  end

  def add_user( user, role )
    unless role.kind_of? Role
      role = Role.get_by_title(role)
    end
    if role.global
      #only nonglobal roles may be set in a project
      raise SaveError, "tried to set global role '#{role_title}' for user '#{user}' in project '#{self.name}'"
    end

    unless user.kind_of? User
      user = User.get_by_login(user)
    end

    logger.debug "adding user: #{user.login}, #{role.title}"
    ProjectUserRoleRelationship.create(
      :db_project => self,
      :user => user,
      :role => role )
  end

  def add_group( group, role )
    unless role.kind_of? Role
      role = Role.get_by_title(role)
    end
    if role.global
      #only nonglobal roles may be set in a project
      raise SaveError, "tried to set global role '#{role_title}' for group '#{group}' in project '#{self.name}'"
    end

    unless group.kind_of? Group
      group = Group.find_by_title(group)
    end

    logger.debug "adding group: #{group.title}, #{role.title}"
    ProjectGroupRoleRelationship.create(
      :db_project => self,
      :group => group,
      :role => role )
  end

  def each_user( opt={}, &block )
    users = User.find :all,
      :select => "bu.*, r.title AS role_name",
      :joins => "bu, project_user_role_relationships purr, roles r",
      :conditions => ["bu.id = purr.bs_user_id AND purr.db_project_id = ? AND r.id = purr.role_id", self.id]
    if( block )
      users.each do |u|
        block.call u
      end
    end
    return users
  end

  def each_group( opt={}, &block )
    groups = Group.find :all,
      :select => "bg.*, r.title AS role_name",
      :joins => "bg, project_group_role_relationships pgrr, roles r",
      :conditions => ["bg.id = pgrr.bs_group_id AND pgrr.db_project_id = ? AND r.id = pgrr.role_id", self.id]
    if( block )
      groups.each do |g|
        block.call g
      end
    end
    return groups
  end

  def to_axml(view = nil)
    unless view
       Rails.cache.fetch('meta_project_%d' % id) do
         render_axml(view)
       end
    else 
      render_axml(view)
    end
  end

  def render_axml(view = nil)
    builder = Nokogiri::XML::Builder.new
    logger.debug "----------------- rendering project #{name} ------------------------"

    project_attributes = {:name => name}
    # Check if the project has a special type defined (like maintenance)
    project_attributes[:kind] = project_type if project_type and project_type != "standard"

    xml = builder.project( project_attributes ) do |project|
      project.title( title )
      project.description( description )
      
      self.linkedprojects.each do |l|
        if l.linked_db_project
           project.link( :project => l.linked_db_project.name )
        else
           project.link( :project => l.linked_remote_project_name )
        end
      end

      project.remoteurl(remoteurl) unless remoteurl.blank?
      project.remoteproject(remoteproject) unless remoteproject.blank?
      project.devel( :project => develproject.name ) unless develproject.nil?

      each_user do |u|
        project.person( :userid => u.login, :role => u.role_name )
      end

      each_group do |g|
        project.group( :groupid => g.title, :role => g.role_name )
      end

      self.downloads.each do |dl|
        project.download( :baseurl => dl.baseurl, :metafile => dl.metafile,
          :mtype => dl.mtype, :arch => dl.architecture.name )
      end

      if view == 'flagdetails'
        flags_to_xml(builder, expand_flags)
      else
        FlagHelper.flag_types.each do |flag_name|
          flaglist = type_flags(flag_name)
          project.send(flag_name) do
            flaglist.each do |flag|
              flag.to_xml(builder)
            end
          end unless flaglist.empty?
        end
      end

      repos = repositories.find( :all, :conditions => "ISNULL(remote_project_name)" )
      repos.each do |repo|
        params = {}
        params[:name]        = repo.name
        params[:rebuild]     = repo.rebuild     if repo.rebuild
        params[:block]       = repo.block       if repo.block
        params[:linkedbuild] = repo.linkedbuild if repo.linkedbuild
        project.repository( params ) do |r|
          repo.release_targets.each do |rt|
            params = {}
            params[:project]    = rt.target_repository.db_project.name
            params[:repository] = rt.target_repository.name
            params[:trigger]    = rt.trigger    unless rt.trigger.blank?
            r.releasetarget( params )
          end
          if repo.hostsystem
            r.hostsystem( :project => repo.hostsystem.db_project.name, :repository => repo.hostsystem.name )
          end
          repo.path_elements.each do |pe|
            if pe.link.remote_project_name
              project_name = pe.link.db_project.name+":"+pe.link.remote_project_name
            else
              project_name = pe.link.db_project.name
            end
            r.path( :project => project_name, :repository => pe.link.name )
          end
          repo.architectures.each do |arch|
            r.arch arch.name
          end
        end
      end

      if self.maintained_projects.length > 0
        project.maintenance do |maintenance|
          self.maintained_projects.each do |mp|
            maintenance.maintains(:project => mp.name)
          end
        end
      end

    end
    logger.debug "----------------- end rendering project #{name} ------------------------"

    return builder.doc.to_xml :indent => 2, :encoding => 'UTF-8', 
                               :save_with => Nokogiri::XML::Node::SaveOptions::NO_DECLARATION |
                                             Nokogiri::XML::Node::SaveOptions::FORMAT
  end

  def to_axml_id
    return "<project name='#{name.to_xs}'/>"
  end


  def rating( user_id=nil )
    score = 0
    self.ratings.each do |rating|
      score += rating.score
    end
    count = self.ratings.length
    score = score.to_f
    score /= count
    score = -1 if score.nan?
    score = ( score * 100 ).round.to_f / 100
    if user_rating = self.ratings.find_by_user_id( user_id )
      user_score = user_rating.score
    else
      user_score = 0
    end
    return { :score => score, :count => count, :user_score => user_score }
  end


  def activity
    # the activity of a project is measured by the average activity
    # of all its packages. this is not perfect, but ok for now.

    # get all packages including activity values, we may not have access
    begin
      @packages = DbPackage.find :all,
        :from => 'db_packages, db_projects',
        :conditions => "db_packages.db_project_id = db_projects.id AND db_projects.id = #{self.id}",
        :select => 'db_projects.*,' +
        "( #{DbPackage.activity_algorithm} ) AS act_tmp," +
        'IF( @activity<0, 0, @activity ) AS activity_value'
      # count packages and sum up activity values
      project = { :count => 0, :sum => 0 }
      @packages.each do |package|
        project[:count] += 1
        project[:sum] += package.activity_value.to_f
      end
      # calculate and return average activity
      return project[:sum] / project[:count]
    rescue
      return
    end
  end


  # calculate enabled/disabled per repo/arch
  def flag_status(default, repo, arch, prj_flags, pkg_flags)
    ret = default
    expl = false

    flags = Array.new
    prj_flags.each do |f|
      flags << f if f.is_relevant_for?(repo, arch)
    end if prj_flags
    flags.sort! { |a,b| a.specifics <=> b.specifics }
    flags.each do |f|
      ret = f.status
      expl = f.is_explicit_for?(repo, arch)
    end

    flags = Array.new
    if pkg_flags
      pkg_flags.each do |f|
        flags << f if f.is_relevant_for?(repo, arch)
      end
      # in case we look at a package, the project flags are not explicit
      expl = false
    end
    flags.sort! { |a,b| a.specifics <=> b.specifics }
    flags.each do |f|
      ret = f.status
      expl = f.is_explicit_for?(repo, arch)
    end

    opts = Hash.new
    opts[:repository] = repo if repo
    opts[:arch] = arch if arch
    opts[:explicit] = '1' if expl
    ret = 'enable' if ret == :enabled
    ret = 'disable' if ret == :disabled
    # we allow to only check the return value
    return ret, opts
  end

  # give out the XML for all repos/arch combos
  def expand_flags(pkg = nil)
    ret = Hash.new
    repos = repositories.find( :all, :conditions => "ISNULL(remote_project_name)", :include => [:architectures] )
    
    FlagHelper.flag_types.each do |flag_name|
      pkg_flags = nil
      flaglist = self.type_flags(flag_name)
      pkg_flags = pkg.type_flags(flag_name) if pkg
      flag_default = FlagHelper.default_for(flag_name)
      archs = Array.new
      flagret = Array.new
      unless [ 'lock', 'access', 'sourceaccess' ].include?(flag_name)
        repos.each do |repo|
          flagret << flag_status(flag_default, repo.name, nil, flaglist, pkg_flags)
          repo.architectures.each do |arch|
            flagret << flag_status(flag_default, repo.name, arch.name, flaglist, pkg_flags)
            archs << arch.name
          end
        end
        archs.uniq.each do |arch|
          flagret << flag_status(flag_default, nil, arch, flaglist, pkg_flags)
        end
      end
      flagret << flag_status(flag_default, nil, nil, flaglist, pkg_flags)
      ret[flag_name] = flagret
    end
    ret
  end

  def complex_status(backend)
    ProjectStatusHelper.calc_status(self, backend)
  end

  # find a package in a project and its linked projects
  def find_package(package_name, processed={})
    # cycle check in linked projects
    if processed[self]
      str = self.name
      processed.keys.each do |key|
        str = str + " -- " + key.name
      end
      raise CycleError.new "There is a cycle in project link defintion at #{str}"
      return nil
    end
    processed[self]=1

    # package exists in this project
    pkg = self.db_packages.find_by_name(package_name)
#    return pkg unless pkg.nil?
    unless pkg.nil?
      return pkg if DbPackage.check_access?(pkg)
    end

    # search via all linked projects
    self.linkedprojects.each do |lp|
      if self == lp.linked_db_project
        raise CycleError.new "project links against itself, this is not allowed"
        return nil
      end

      if lp.linked_db_project.nil?
        # We can't get a package object from a remote instance ... how shall we handle this ?
        pkg = nil
      else
        pkg = lp.linked_db_project.find_package(package_name, processed)
      end
      unless pkg.nil?
        return pkg if DbPackage.check_access?(pkg)
      end
    end

    # no package found
    processed.delete(self)
    return nil
  end

  def project_type
    mytype = DbProjectType.find_by_id(type_id) if type_id
    return 'standard' unless mytype
    return mytype.name
  end

  def set_project_type(project_type_name)
    mytype = DbProjectType.find_by_name(project_type_name)
    return false unless mytype
    self.type_id = mytype.id
    self.save!
    return true
  end

  def maintenance_project
    return DbProject.find_by_id(maintenance_project_id)
  end

  def set_maintenance_project(project)
    if project.class == DbProject
      self.maintenance_project_id = project.id
      self.save!
      return true
    elsif project.class == String
      prj = DbProject.find_by_name(project)
      if prj
        self.maintenance_project_id = prj.id
        self.save!
        return true
      end
    end
    return false
  end

  def open_requests_with_project_as_source_or_target
    # Includes also requests for packages contained in this project
    predicate = "(state/@name='new' or state/@name='review' or state/@name='declined') and (action/source/@project='#{self.name}' or action/target/@project='#{self.name}')"
    collection = Suse::Backend.post("/search/request?match=#{CGI.escape(predicate)}", nil).body
    return collection.scan(/request id\="(\d+)"/).flatten # A list of request ids
  end

  def open_requests_with_by_project_review
    # Includes also by_package reviews for packages contained in this project
    predicate = "(state/@name='new' or state/@name='review') and (review[@state='new' and @by_project='#{self.name}'])"
    collection = Suse::Backend.post("/search/request?match=#{CGI.escape(predicate)}", nil).body
    return collection.scan(/request id\="(\d+)"/).flatten # A list of request ids
  end

  # list only the repositories that have a target project in the build path
  # the function uses the backend for informations (TODO)
  def repositories_linking_project(tproj, backend)
    tocheck_repos = Array.new

    targets = bsrequest_repos_map(tproj.name, backend)
    sources = bsrequest_repos_map(self.name, backend)
    sources.each do |key, value|
      if targets.has_key?(key)
        tocheck_repos << sources[key]
      end
    end

    tocheck_repos.flatten!
    tocheck_repos.uniq
  end

  def bsrequest_repos_map(project, backend)
    ret = Hash.new
    uri = URI( "/getprojpack?project=#{CGI.escape(project.to_s)}&nopackages&withrepos&expandedrepos" )
    begin
      xml = ActiveXML::Base.new( backend.direct_http( uri ) )
    rescue ActiveXML::Transport::Error
      return ret
    end
    xml.project.each_repository do |repo|
      repo.each_path do |path|
        ret[path.project.to_s] ||= Array.new
        ret[path.project.to_s] << repo
      end
    end if xml.project

    return ret
  end
  private :bsrequest_repos_map
    
end
