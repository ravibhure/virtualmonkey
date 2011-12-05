# To use with thin
# thin start -p PORT -R config.ru

$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), "..")))

ENV['ENTRY_COMMAND'] ||= File.basename(__FILE__, ".rb")

require 'rubygems'
require File.join('..', 'spidermonkey')

module VirtualMonkey
  PUBLIC_HOSTNAME = (VirtualMonkey::my_api_self ? VirtualMonkey::my_api_self.reachable_ip : ENV['REACHABLE_IP'])
end

require 'sinatra'

# disable sinatra's auto-application starting
#disable :run

set :environment, :development #:test, :production

set :sessions, :domain => VirtualMonkey::PUBLIC_HOSTNAME # TODO Configure these cookies to work securely
set :bind, '0.0.0.0'
set :port, 443
set :static, false
set :dump_errors, true
set :logging, true
#set :public_folder, VirtualMonkey::WEB_APP_PUBLIC_DIR

# Due to the reading/writing of JSON cache files, this application is not thread-safe.
# Disable :lock after installing redis or another similar cacheing mechanism
set :lock, true

#set :ssl, lambda { !development? }
#use Rack::SSL, :exclude => lambda { !ssl? }
#use Rack::Session::Cookie, :expire_after => 1.week, :secret => ''

use Rack::Auth::Basic, "Restricted Area" do |username, password|
  headers = {'Authorization' => "Basic #{["#{username}:#{password}"].pack('m').delete("\r\n")}",
             'X_API_VERSION' => '1.0'}
  connection = Excon.new('https://my.rightscale.com', :headers => headers)
  settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))
  success = false

  begin
    resp = connection.get(:path => "#{settings[:api_url]}/servers.js?")
    success = (resp.status == 200)
  rescue Exception => e
  end

  # TODO CACHING!!!!

  session[:virutalmonkey_id] = rand(1000000)
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

  def standard_handlers(&block)
    yield
  rescue Excon::Errors::HTTPStatusError => e
    status((e.message =~ /Actual\(([0-9]+)\)/; $1.to_i))
    body(e.response)
  rescue ArgumentError, TypeError => e
    status 400
    body(e.message)
  rescue NotImplementedError => e
    status 501
    body(e.message)
  rescue IndexError, NameError => e
    status 404
    body(e.message)
  rescue Exception => e
    status 500
    body(e.message)
  end
end

# ==========================
# VirtualMonkey Commands API
# ==========================
# Each command creates a new task resource. Tasks are temporary, and must
# be explicitly saved to persist longer than the instance.

VirtualMonkey::Command::NonInteractiveCommands.keys.each do |cmd|
  post "#{VirtualMonkey::API::ROOT}/#{cmd.to_s}" do
    standard_handlers do
      opts = get_cmd_flags(cmd, JSON.parse(request.body))
      opts |= ["--report_metadata"] if cmd == "run" || cmd == "troop"
      # TODO: Sanitize...

      task_uid = VirtualMonkey::API::Task.create("command" => cmd, "options" => opts)

      status 201
      headers "Location" => "#{VirtualMonkey::API::Task.collection_path}/#{task_uid}",
              "Content-Type" => "#{VirtualMonkey::API::Task::ContentType}"
    end
  end
end

# =========
# Tasks API
# =========

# Index
get VirtualMonkey::API::Task::PATH do
  standard_handlers do
    body VirtualMonkey::API::Task.index().to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Task::CollectionContentType}"
  end
end

# Create
post VirtualMonkey::API::Task::PATH do
  standard_handlers do
    task_uid = VirtualMonkey::API::Task.create(JSON.parse(request.body))
    status 201
    headers "Location" => "#{VirtualMonkey::API::Task.collection_path}/#{task_uid}"
  end
end

# Read
get "#{VirtualMonkey::API::Task::PATH}/:task_uid" do |task_uid|
  standard_handlers do
    body VirtualMonkey::API::Task.get(task_uid).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Task::ContentType}"
  end
end

# Update
put "#{VirtualMonkey::API::Task::PATH}/:task_uid" do |task_uid|
  standard_handlers do
    VirtualMonkey::API::Task.put(task_uid, JSON.parse(request.body))
    body ""
    status 204
  end
end

# Delete
delete "#{VirtualMonkey::API::Task::PATH}/:task_uid" do |task_uid|
  standard_handlers do
    VirtualMonkey::API::Task.delete(task_uid)
    body ""
    status 204
  end
end

# Save
post "#{VirtualMonkey::API::Task::PATH}/:task_uid/save" do |task_uid|
  standard_handlers do
    VirtualMonkey::API::Task.save(task_uid)
    body ""
    status 204
  end
end

# Schedule
post "#{VirtualMonkey::API::Task::PATH}/:task_uid/schedule" do |task_uid|
  standard_handlers do
    VirtualMonkey::API::Task.schedule(task_uid, JSON.parse(request.body))
    body ""
    status 204
  end
end

# Start
post "#{VirtualMonkey::API::Task::PATH}/:task_uid/start" do |task_uid|
  standard_handlers do
    job_uid = VirtualMonkey::API::Task.start(task_uid)
    status 201
    headers "Location" => "#{VirtualMonkey::API::Job::PATH}/#{job_uid}",
            "Content-Type" => "#{VirtualMonkey::API::Job::ContentType}"
  end
end

# =============
# Job Queue API
# =============

# Index
get VirtualMonkey::API::Job::PATH do
  standard_handlers do
    body VirtualMonkey::API::Job.index()
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Job::CollectionContentType}"
  end
end

# Create
post VirtualMonkey::API::Job::PATH do
  standard_handlers do
    job_uid = VirtualMonkey::API::Job.create(JSON.parse(request.body))
    status 201
    headers "Location" => "#{VirtualMonkey::API::Job::PATH}/#{job_uid}"
  end
end

# Read
get "#{VirtualMonkey::API::Job::PATH}/:job_uid" do |job_uid|
  standard_handlers do
    body VirtualMonkey::API::Job.get(job_uid).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Job::ContentType}"
  end
end

# Delete
delete "#{VirtualMonkey::API::Job::PATH}/:job_uid" do |job_uid|
  standard_handlers do
    VirtualMonkey::API::Job.delete(job_uid)
    body ""
    status 204
  end
end

# ==========
# Report API
# ==========

# Index
get VirtualMonkey::API::Report::PATH do
  standard_handlers do
    body VirtualMonkey::API::Report::index(JSON.parse(request.body)).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Report::CollectionContentType}"
  end
end

# Read
get "#{VirtualMonkey::API::Report::PATH}/:report_uid" do |report_uid|
  standard_handlers do
    body VirtualMonkey::API::Report::get(report_uid).to_json
    status 200
    headers "Content-Type" => "#{VirtualMonkey::API::Report::ContentType}"
  end
end

# Delete
# TODO

# Details
# TODO

# ============
# Static Files
# ============

get "/*" do
  IO.read(File.join(VirtualMonkey::WEB_APP_PUBLIC_DIR, *(params[:splat].split(/\//))))
end
