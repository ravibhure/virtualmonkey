module VirtualMonkey
  module Mixin
    module PhpChef

      def set_mysql_fqdn
 				the_name = mysql_servers.first.dns_name
        @deployment.set_input("db_mysql/fqdn", "text:#{the_name}")
			end
		
      def disable_reconverge
        run_script_on_set('disable_reconverge', fe_servers)
      end

      def detach_all
        run_script_on_set('detach', app_servers)
      end

      def detach_checks
        probe(fe_servers, "sed -n '/^[ \t]*server/p' /home/haproxy/rightscale_lb.cfg") { |result, status|
          raise "Detach failed, servers are left in /home/haproxy/rightscale_lb.cfg - #{result}" unless result.empty?
          raise "Detach failed, status returned #{status}" unless status == 0
          true
        }
      end

      def enable_reconverge
        run_script_on_set('enable_reconverge', fe_servers)
      end

      def php_chef_fe_lookup_scripts
        recipes = [
                    [ 'attach_all', 'lb_haproxy::do_attach_all' ],
                    [ 'disable_reconverge', 'lb_haproxy::do_disable_reconverge' ],
                    [ 'enable_reconverge', 'lb_haproxy::setup_reconverge' ]
                  ]
        fe_st = ServerTemplate.find(resource_id(fe_servers.first.server_template_href))
        load_script_table(fe_st,recipes)
      end
  
      def php_chef_app_lookup_scripts
        recipes = [
                    [ 'attach', 'lb_haproxy::do_attach_request' ],
                    [ 'detach', 'lb_haproxy::do_detach_request' ],
                    [ 'update_code', 'app_php::do_update_code' ]
                  ]
        app_st = ServerTemplate.find(resource_id(app_servers.first.server_template_href))
        load_script_table(app_st,recipes)
      end
  
      def test_detach
        run_script_on_set('detach', app_servers)
        detach_checks
      end
  
      def test_attach_all
        run_script_on_set('attach_all', fe_servers)
      end
  
      def test_attach_request 
        run_script_on_set('attach', app_servers)
      end
  
      def set_variation_http_only
        @deployment.set_input("web_apache/ssl_enable", "text:false")
      end

      def set_variation_cron_time
        @deployment.set_input("lb_haproxy/cron_reconverge_hour", "text:*")
        @deployment.set_input("lb_haproxy/cron_reconverge_minute", "text:*")
      end

      def set_variation_ssl
        @deployment.set_input("web_apache/ssl_enable", "text:true")
        @deployment.set_input("web_apache/ssl_key", "cred:virtual_monkey_key")
        @deployment.set_input("web_apache/ssl_certificate", "cred:virtual_monkey_certificate")
        @deployment.set_input("web_apache/ssl_certificate_chain", "ignore:$ignore")
        @deployment.set_input("web_apache/ssl_passphrase", "ignore:$ignore")
      end

      def set_variation_ssl_chain
        fe_servers.first.set_info_tags({'ssl_chain' => 'true'})
        ssl_chain_server.set_inputs({"web_apache/ssl_certificate_chain" => "cred:virtual_monkey_certificate_chain"})
      end

      def set_variation_ssl_passphrase
        fe_servers.first.set_info_tags({'ssl_passphrase' => 'true'})
        inputs = {"web_apache/ssl_enable" => "text:true",
                  "web_apache/ssl_key" => "cred:virtual_monkey_key_withpass",
                  "web_apache/ssl_certificate" => "cred:virtual_monkey_certificate_withpass",
                  "web_apache/ssl_passphrase" => "cred:virtual_monkey_certificate_passphrase"}
        ssl_passphrase_server.set_inputs(inputs)
      end

      def ssl_chain_server
        fe_servers.detect { |s| s.get_info_tags('ssl_chain')['self']['ssl_chain'] == 'true' }
      end

      def ssl_passphrase_server
        fe_servers.detect { |s| s.get_info_tags('ssl_passphrase')['self']['ssl_passphrase'] == 'true' }
      end

      def test_ssl_chain
        puts `openssl s_client -showcerts -connect "#{ssl_chain_server.dns_name}:443" < /dev/null |grep Equifax`
	raise "FATAL: no certificate chain for Equifax detected." unless $?.success?
      end
 
		end
	end 
end