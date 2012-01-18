# To use with thin
# thin start -p PORT -R config.ru

$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), "..")))

ENV['ENTRY_COMMAND'] ||= File.basename(__FILE__, ".rb")

require 'rubygems'
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'virtualmonkey'))

module VirtualMonkey
  def self.script_tag(url)
    "<script type='text/javascript' src='#{url}'></script>"
  end

  PUBLIC_HOSTNAME = (VirtualMonkey::my_api_self ? VirtualMonkey::my_api_self.reachable_ip : ENV['REACHABLE_IP'])
  JQUERY = script_tag("http://ajax.googleapis.com/ajax/libs/jquery/1.7/jquery.min.js")
  JQUERY_UI = script_tag("http://cdnjs.cloudflare.com/ajax/libs/jqueryui/1.8.13/jquery-ui.min.js")
  MODERNIZR = script_tag("http://cdnjs.cloudflare.com/ajax/libs/modernizr/2.0.6/modernizr.min.js")
  BOOTSTRAP_TABS = script_tag("/js/bootstrap-tabs.js")
  BOOTSTRAP_POPOVER = script_tag("/js/bootstrap-popover.js")
  BOOTSTRAP_BUTTONS = script_tag("/js/bootstrap-buttons.js")
  BOOTSTRAP_MODAL = script_tag("/js/bootstrap-modal.js")
  INIT_JS = script_tag("/js/init.js")
  ACTIONS_JS = script_tag("/js/actions.js")
  MAIN_JS = script_tag("/js/main.js")

  HTML5_SHIM = <<-EOS
    <!--[if lt IE 9]>
      <script type="text/javascript" src="/js/excanvas.min.js"></script>
      <script src="http://html5shim.googlecode.com/svn/trunk/html5.js"></script>
    <![endif]-->
  EOS

#  BOOTSTRAP_JS = [BOOTSTRAP_MODAL, BOOTSTRAP_TABS, BOOTSTRAP_POPOVER, BOOTSTRAP_BUTTONS].join("\n")
  BOOTSTRAP_JS = script_tag("/js/bootstrap.js")
  BOOTSTRAP_RAW_JAVASCRIPT = lambda {
    bootstraps = Dir["public/js/bootstrap*"]
    if twipsy = bootstraps.detect { |f| f =~ /twipsy/ }
      bootstraps.unshift(bootstraps.delete(twipsy))
    end
    return bootstraps.map { |js| IO.read(js) }.join("\n")
  }.call

  ALL_JS = [
            JQUERY,
            JQUERY_UI,
            MODERNIZR,
            HTML5_SHIM,
            BOOTSTRAP_TABS,
            BOOTSTRAP_POPOVER,
            BOOTSTRAP_BUTTONS,
            BOOTSTRAP_MODAL,
            INIT_JS,
            ACTIONS_JS,
           ].join("\n")

  #STYLESHEET = %q{<link rel="stylesheet/less" type="text/css" href="/css/virtualmonkey.less" />}
  STYLESHEET = %q{<link rel="stylesheet" type="text/css" href="/css/virtualmonkey.css" />}
  LESS_JS = script_tag("http://cdnjs.cloudflare.com/ajax/libs/less.js/1.1.3/less-1.1.3.min.js")

  INDEX_TITLE = "VirtualMonkey WebUI"
  CachedLogins = {}
  RACK_ENV = lambda {
    default = :development
    if File.writable?(SYS_CRONTAB)
      default = :production
    else
      STDERR.puts("File #{SYS_CRONTAB} is not writable! You may not get expected behavior")
    end
    return (ENV["RACK_ENV"] || default).to_sym
  }.call
end

require 'sinatra'
require 'partials'
require 'erb'
require 'less'
require 'digest/sha1'

# disable sinatra's auto-application starting
#disable :run

set :environment, VirtualMonkey::RACK_ENV
set :server, %w[mongrel] # thin, awesome though it may be, uses EventMachine. And so do we.

set :sessions, :domain => VirtualMonkey::PUBLIC_HOSTNAME # TODO Configure these cookies to work securely
set :bind, '0.0.0.0'
set :port, (VirtualMonkey::RACK_ENV == :production ? 443 : 8888)
#set :static, false
set :static_cache_control, [:public, {:max_age => 300}]
set :threaded, true
set :dump_errors, (VirtualMonkey::RACK_ENV == :development)
set :logging, true
set :views, 'views'
#set :public_folder, VirtualMonkey::WEB_APP_PUBLIC_DIR

# Due to the reading/writing of JSON cache files, this application is not thread-safe.
# Disable :lock after installing redis or another similar caching mechanism
#set :lock, true

#set :ssl, lambda { !development? }
#use Rack::SSL, :exclude => lambda { !ssl? }
#use Rack::Session::Cookie, :expire_after => 1.week, :secret => ''

use Rack::Auth::Basic, "Restricted Area" do |username, password|
  hash = Digest::SHA1.hexdigest(password)
  #session[:username] = username
  success = (VirtualMonkey::RACK_ENV == :development)
  if success || VirtualMonkey::CachedLogins[username] == password
    success = true
  else
    headers = {'Authorization' => "Basic #{["#{username}:#{password}"].pack('m').delete("\r\n")}",
               'X_API_VERSION' => '1.0'}
    connection = Excon.new('https://my.rightscale.com', :headers => headers)
    settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))

    begin
      resp = connection.get(:path => "#{settings[:api_url].split(/\//)[-3,3].join('/')}/credentials.js?")
      success = (resp.status == 200)
    rescue Exception => e
      STDERR.puts(e)
    end

    VirtualMonkey::CachedLogins[username] = password if success

    #session[:virutalmonkey_id] = rand(1000000)
  end
  success
end

helpers do
  def get_cmd_flags(cmd, parameters={})
    opts = parameters.map { |key,val|
      ret = "--#{key}"
      val = val.join(" ") if val.is_a?(Array)
      if val.is_a?(TrueClass)
      elsif val.is_a?(FalseClass)
        ret = nil
      else
        ret += " #{val}"
      end
      ret
    }
    opts.compact!
    opts |= ["--yes"]
  end

  def get_user()
    {"user" => session[:username]}
  end

  def get_error_message(e)
    if VirtualMonkey::RACK_ENV == :development
      return "#{e}\n#{e.backtrace.join("\n")}"
    else
      return "#{e.message}"
    end
  end

  def standard_handlers(&block)
    data = (request.POST() || {})
    data = params.dup unless params.empty?
    yield(data)
  rescue Excon::Errors::HTTPStatusError => e
    status((e.message =~ /Actual\(([0-9]+)\)/; $1.to_i))
    body e.response
  rescue ArgumentError, TypeError => e
    status 400
    body get_error_message(e)
  rescue VirtualMonkey::API::MethodNotAllowedError => e
    status 405
    body get_error_message(e)
  rescue NotImplementedError => e
    status 501
    body get_error_message(e)
  rescue IndexError, NameError, Errno::EBADF, Errno::ENOENT => e
    status 404
    body get_error_message(e)
  rescue VirtualMonkey::API::SemanticError => e
    status 422
    body get_error_message(e)
#  rescue Exception => e
#    status 500
#    body get_error_message(e)
  end

  def set_context(symbol)
    @context = symbol.to_sym
    instance_eval("def #{@context}?; #{@context.inspect} == @context; end")
  end
end

helpers Sinatra::Partials

# Default Layout Template
template :layout do
  <<-EOS
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <% if (@title ||= nil) %>
          <title><%= @title %></title>
        <% end %>
        <link rel="shortcut icon" href="/favicon2.ico" type="image/x-icon" />
        <link rel="icon" href="/favicon2.ico" type="image/x-icon" />
        #{VirtualMonkey::JQUERY}
        #{VirtualMonkey::JQUERY_UI}
        #{VirtualMonkey::MODERNIZR}
        #{VirtualMonkey::HTML5_SHIM}
        #{VirtualMonkey::INIT_JS}
        #{VirtualMonkey::STYLESHEET}
      </head>
      <body>
        <%= yield %>
        #{VirtualMonkey::BOOTSTRAP_JS}
        #{VirtualMonkey::ACTIONS_JS}
      </body>
    </html>
  EOS
end

# ==========================
# VirtualMonkey Commands API
# ==========================
# Each command creates a new task resource. Tasks are temporary, and must
# be explicitly saved to persist longer than the instance.

VirtualMonkey::Command::NonInteractiveCommands.keys.each do |cmd|
  post "#{VirtualMonkey::API::ROOT}/#{cmd.to_s}" do
    standard_handlers do |data|
      opts = get_cmd_flags(cmd, data)
      opts |= ["--report_metadata"] if cmd == "run" || cmd == "troop"
      # TODO - later: Sanitize...

      uid = VirtualMonkey::API::Task.create("command" => cmd, "options" => opts)

      status 201
      headers "Location" => "#{VirtualMonkey::API::Task::PATH}/#{uid}",
              "Content-Type" => "#{VirtualMonkey::API::Task::ContentType}"
    end
  end
end

# =========
# Tasks API
# =========

# Index
get VirtualMonkey::API::Task::PATH do
  standard_handlers do |data|
    body VirtualMonkey::API::Task.index().to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Task::CollectionContentType}"
  end
end

# Create
post VirtualMonkey::API::Task::PATH do
  standard_handlers do |data|
    uid = VirtualMonkey::API::Task.create(data.merge(get_user))
    status 201
    headers "Location" => "#{VirtualMonkey::API::Task::PATH}/#{uid}"
  end
end

# Read
get "#{VirtualMonkey::API::Task::PATH}/:uid" do |uid|
  standard_handlers do |data|
    body VirtualMonkey::API::Task.get(uid).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Task::ContentType}"
  end
end

# Update
put "#{VirtualMonkey::API::Task::PATH}/:uid" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Task.update(uid, data.merge(get_user))
    body ""
    status 204
  end
end

# Delete
delete "#{VirtualMonkey::API::Task::PATH}/:uid" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Task.delete(uid)
    body ""
    status 204
  end
end

# Save
post "#{VirtualMonkey::API::Task::PATH}/:uid/save" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Task.save(uid)
    body ""
    status 204
  end
end

# Purge
post "#{VirtualMonkey::API::Task::PATH}/:uid/purge" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Task.purge(uid)
    body ""
    status 204
  end
end

# Schedule
post "#{VirtualMonkey::API::Task::PATH}/:uid/schedule" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Task.schedule(uid, data.merge(get_user))
    body ""
    status 204
  end
end

# Start
post "#{VirtualMonkey::API::Task::PATH}/:uid/start" do |uid|
  standard_handlers do |data|
    ret_val = VirtualMonkey::API::Task.start(uid, get_user)
    if ret_val.is_a?(Array)
      status 201
      headers "Location" => "#{VirtualMonkey::API::Job::PATH}",
              "Content-Type" => "#{VirtualMonkey::API::Job::CollectionContentType}"
      body(ret_val.map { |uid| VirtualMonkey::API::Job.get(uid) }.to_json)
    else
      status 201
      headers "Location" => "#{VirtualMonkey::API::Job::PATH}/#{ret_val}"
    end
  end
end

# =============
# Job Queue API
# =============

# Index
get VirtualMonkey::API::Job::PATH do
  standard_handlers do |data|
    VirtualMonkey::API::Job.garbage_collect()
    body VirtualMonkey::API::Job.index().to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Job::CollectionContentType}"
  end
end

# Create
post VirtualMonkey::API::Job::PATH do
  standard_handlers do |data|
    VirtualMonkey::API::Job.garbage_collect()
    uid = VirtualMonkey::API::Job.create(data)
    status 201
    headers "Location" => "#{VirtualMonkey::API::Job::PATH}/#{uid}"
  end
end

# Read
get "#{VirtualMonkey::API::Job::PATH}/:uid" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Job.garbage_collect()
    body VirtualMonkey::API::Job.get(uid).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Job::ContentType}"
  end
end

# Delete
delete "#{VirtualMonkey::API::Job::PATH}/:uid" do |uid|
  standard_handlers do |data|
    VirtualMonkey::API::Job.delete(uid)
    body ""
    status 204
  end
end

# Garbage Collect
post "#{VirtualMonkey::API::Job::PATH}/garbage_collect" do
  standard_handlers do |data|
    VirtualMonkey::API::Job.garbage_collect()
    body ""
    status 204
  end
end

# ==========
# Report API
# ==========

# Index
get VirtualMonkey::API::Report::PATH do
  standard_handlers do |data|
    body VirtualMonkey::API::Report.index(data).to_json
    status 200
#    headers "Content-Type" => "#{VirtualMonkey::API::Report::CollectionContentType}"
  end
end

# Read
get "#{VirtualMonkey::API::Report::PATH}/:uid" do |uid|
  pass if uid == "autocomplete"
  standard_handlers do |data|
    body VirtualMonkey::API::Report.get(uid).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Report::ContentType}"
  end
end

# Delete
# TODO - later

# Details
# TODO - later


# ================
# Autocomplete API
# ================

get "#{VirtualMonkey::API::Report::PATH}/autocomplete" do
  standard_handlers do |data|
    body VirtualMonkey::API::Report::autocomplete.to_json
    status 200
  end
end

# =========
# Web Pages
# =========

get "/" do
  @title = VirtualMonkey::INDEX_TITLE
  erb :index
end

get "/manager" do
  @title = "VirtualMonkey Manager"
  erb :manager
end

get "/edit_task/:uid" do |uid|
  @actions = ["delete"]
  @edit, @title = nil, nil
  if uid != "new"
    @edit = VirtualMonkey::API::Task.get(uid)
    @title = "Editing Task #{@edit["name"]} (#{@edit.uid})"
  end
  erb :subtasks, :layout => :edit_task
end

get "/tasks/:uid" do |uid|
  @actions = (params["actions"] || ["delete"])
  partial :task, :collection => [VirtualMonkey::API::Task.get(uid)]
end

get "/tasks" do
  @actions = (params["actions"] || ["delete"])
  erb :tasks, :layout => false
end

get "/jobs/:uid" do |uid|
  @actions = (params["actions"] || ["cancel"])
  partial :job, :collection => [VirtualMonkey::API::Job.get(uid)]
end

get "/jobs" do
  @actions = (params["actions"] || ["cancel"])
  erb :jobs, :layout => false
end

get "/css/virtualmonkey.css" do
  less :virtualmonkey, :views => File.join("public", "css")
end

get "/js/bootstrap.js" do
  body VirtualMonkey::BOOTSTRAP_RAW_JAVASCRIPT
  status 200
end

# ============
# Static Files
# ============

#get "/*" do
#  IO.read(File.join(VirtualMonkey::WEB_APP_PUBLIC_DIR, *(params[:splat].split(/\//))))
#end
