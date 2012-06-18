# encoding: UTF-8
require File.expand_path(File.dirname(__FILE__) + "/..") + "/test_helper"
require 'source_controller'

class CrossBuildTest < ActionController::IntegrationTest 
  fixtures :all
  
  def test_setup_project
    prepare_request_with_user "tom", "thunder"
    put "/source/home:tom:CrossBuild/_meta", "<project name='home:tom:CrossBuild'> <title/> <description/>
            <repository name='standard'>
              <path repository='BaseDistro_repo' project='BaseDistro' />
              <hostsystem repository='BaseDistro2_repo' project='BaseDistro2.0' />
            </repository>
          </project>"
    assert_response :success
    get "/source/home:tom:CrossBuild/_meta"
    assert_response :success
    assert_xml_tag :tag => "path", :attributes => { :project => 'BaseDistro', :repository => 'BaseDistro_repo' }
    assert_xml_tag :tag => "hostsystem", :attributes => { :project => 'BaseDistro2.0', :repository => 'BaseDistro2_repo' }

  end

end
