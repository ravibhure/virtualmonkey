require 'rubygems'

module VirtualMonkey
  WEB_APP_PUBLIC_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "public").freeze
  API_CONTROLLERS_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "api_controllers").freeze
  SYS_CRONTAB = File.join("", "etc", "crontab").freeze

  module API
    ROOT = "/api"
  end
end

progress_require('cronedit')
progress_require('chronic')
progress_require('spidermonkey/api_controllers')
