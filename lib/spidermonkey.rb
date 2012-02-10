require 'rubygems'

module VirtualMonkey
  WEB_APP_PUBLIC_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "public").freeze
  API_CONTROLLERS_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "api_controllers").freeze
  VIEWS_DIR = File.join(VirtualMonkey::WEB_APP_DIR, "views").freeze
  SYS_CRONTAB = File.join("", "etc", "crontab").freeze

  module API
    ROOT = "/api"
  end

  module CertificateHandler
    def self.generate_self_signed_certificate
      type = "pem" # || "der"
      privateKeyFile = File.join(VirtualMonkey::ROOTDIR, "virtualmonkey.key")
      publicKeyFile = File.join(VirtualMonkey::ROOTDIR, "virtualmonkey.crt")

      values = [{ 'C' => 'US'},
                {'ST' => 'California'},
                { 'L' => 'Santa Barbara'},
                { 'O' => 'RightScale'},
                {'OU' => 'QA'},
                {'CN' => "somesite.com"}] #TODO - What dns?

      name = values.collect{ |l| l.collect { |k, v| "/#{k}=#{v}" }.join }.join

      key = OpenSSL::PKey::RSA.generate(1024)
      pub = key.public_key
      ca = OpenSSL::X509::Name.parse(name)
      cert = OpenSSL::X509::Certificate.new
      cert.version = 2
      cert.serial = 1
      cert.subject = ca
      cert.issuer = ca
      cert.public_key = pub
      cert.not_before = Time.now
      cert.not_before = Time.now + (360 * 24 * 3600)

      File.open(privateKeyFile + "." + type, "w") {|f| f.write key.send("to_#{type}") }
      File.open(publicKeyFile + "." + type, "w") {|f| f.write cert.send("to_#{type}") }
    end
  end
end

progress_require('cronedit')
progress_require('chronic')
progress_require('spidermonkey/api_controllers')
