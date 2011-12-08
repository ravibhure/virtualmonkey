require 'rubygems'

module VirtualMonkey
  WEB_APP_PUBLIC_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "public")
  API_CONTROLLERS_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "api_controllers")

  module API
    ROOT = "/api"
  end
end

progress_require('spidermonkey/api_controllers')
