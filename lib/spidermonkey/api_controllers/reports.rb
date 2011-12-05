module VirtualMonkey
  module API
    class Report < VirtualMonkey::API::BaseResource
      PATH = "#{VirtualMonkey::API::ROOT}/reports".freeze
      ContentType = "application/vnd.rightscale.virtualmonkey.report"
      CollectionContentType = ContentType + ";type=collection"
      TEMP_STORE = File.join("", "tmp", "spidermonkey_reports.json").freeze
      BASE_DOMAIN = "virtualmonkey_report_metadata".freeze

      #
      # Helper Methods
      #
      private

      def self.read_cache
        JSON::parse(IO.read(TEMP_STORE))
      rescue Errno::ENOENT
        File.open(TEMP_STORE, "w") { |f| {}.to_json }
        return {}
      end
      private_class_method :read_cache

      def self.write_cache(json_hash)
        File.open(TEMP_STORE, "w") { |f| json_hash.to_json }
      end
      private_class_method :write_cache

      def self.fields
        [
          "user_email",
          "user_name",
          "mci_name",
          "mci_href",
          "mci_os",
          "mci_os_version",
          "mci_arch",
          "mci_rightlink",
          "mci_rev",
          "mci_id",
          "servertemplate_name",
          "servertemplate_href",
          "servertemplate_rev",
          "servertemplate_id",
          "cloud_name",
          "cloud_id",
          "instancetype_name",
          "instancetype_href",
          "datacenter_name",
          "datacenter_href",
          "troop",
          "tags",
          "from_date",
          "to_date",
        ]
      end
      private_class_method :fields

      def self.new_sdb_connection
  #      Fog::AWS::SimpleDB.new() # Local Development
        Fog::AWS::SimpleDB.new(:aws_access_key_id => Fog.credentials[:aws_access_key_id_test],
                               :aws_secret_access_key => Fog.credentials[:aws_secret_access_key_test])
      end
      private_class_method :new_sdb_connection

      def self.new_s3_connection
  #      Fog::Storage.new(:provider => "AWS") # Local Development
        Fog::Storage.new(:provider => "AWS",
                         :aws_access_key_id => Fog.credentials[:aws_access_key_id_test],
                         :aws_secret_access_key => Fog.credentials[:aws_secret_access_key_test])
      end
      private_class_method :new_s3_connection

      def self.ensure_domain_exists(domain=this_month_domain)
        # If domain doesn't exist, create domain
        sdb = new_sdb_connection
        sdb.create_domain(domain) unless sdb.list_domains.body["Domains"].include?(domain)
      end
      private_class_method :ensure_domain_exists

      def self.read_single_record_sdb(uid)
        uid = normalize_uid(uid)
        sdb = new_sdb_connection
        domain_to_check = BASE_DOMAIN + uid[0..5]
        unless sdb.list_domains.body["Domains"].include?(domain_to_check)
          raise IndexError.new("#{self} #{uid} not found")
        end
        record = sdb.get_attributes(domain_to_check, uid).body["Attributes"]
        raise IndexError.new("#{self} #{uid} not found") unless record

        # Cache
        if record["status"] =~ /^(cancelled|failed|passed)$/
          cache = read_cache
          cache[uid] = self.new.deep_merge(record)
          write_cache(cache)
        end

        return record
      end
      private_class_method :read_single_record_sdb

      def self.read_range_sdb(start_date, end_date)
        sdb = new_sdb_connection

        # Standardize date formats (Accepts W3C/ISO_8601, "yyyymmdd", "yyyy/mm/dd", and "yyyy_mm_dd")
        start_date, end_date = [start_date, end_date].map { |d| d.split(/\/|-|_/).join("")[0..7] }
        start_stamp, end_stamp = [start_date, end_date].map { |d| [d[0..3], d[4..5], d[6..7]].join("/") }
        start_domain, end_domain = [start_date, end_date].map { |d| BASE_DOMAIN + d[0..5] }
        raise ArgumentError.new("end_date must be greater than start_date") unless end_date >= start_date

        # Get array of domains to query
        domains = [end_domain]
        while start_domain != domains.last
          domains << previous_month_domain(domains.last)
        end
        # Reject domains that don't exist in our account
        domains &= sdb.list_domains.body["Domains"]

        records = []
        domains.each do |domain|
          begin
            current_items = sdb.select("SELECT * from #{domain}").body["Items"]
          rescue Excon::Errors::ServiceUnavailable
            warn "Got \"ServiceUnavailable\", retrying..."
            sleep 2
            retry
          end
          # Reject by created_at timestamps
          if domain == start_domain
            current_items.reject! { |key,hsh| hsh["created_at"] < start_stamp }
          end
          if domain == end_domain
            current_items.reject! do |key,hsh|
              hsh["created_at"] > end_stamp && hsh["created_at"] !~ /^#{start_stamp}/
            end
          end
          records << current_items.values
        end

        # Cache
        to_cache = records.reject { |record| record["status"] !~ /^(cancelled|failed|passed)$/ }
        unless to_cache.empty?
          cache = read_cache
          cache.deep_merge(to_cache.map { |record| [record.uid, self.new.deep_merge(record)] }.to_h)
          write_cache(cache)
        end

        return records
      end
      private_class_method :read_range_sdb

      def self.this_month_domain
        [BASE_DOMAIN, Time.now.year, ("%02d" % Time.now.month)].join("")
      end
      private_class_method :this_month_domain

      def self.previous_month_domain(current_domain=nil)
        y, m = Time.now.year, Time.now.month
        y, m = (current_domain =~ /#{BASE_DOMAIN}([0-9]{4})([0-9]{2})/; [$1.to_i, $2.to_i]) if inStr

        y -= ((m == 1) ? 1 : 0)
        m = ((m + 10) % 12) + 1
        [BASE_DOMAIN, y, ("%02d" % m)].join("")
      end
      private_class_method :this_month_domain

      #
      # Constructor and Instance Methods
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        report_uid = Time.now.strftime("%Y%m%d%H%M%S#{rand(1000000)}")
        self.actions |= [
          {"rel" => "details"}
        ]
        self.links |= [
          {"href" => self.class::PATH + "/#{report_uid}",
           "rel" => "self"},
        ]
        self["uid"] = report_uid
        self
      end

      #
      # API
      #
      public

      def self.index(opts={})
        # Sanitize Keys
        opts &= fields
        from_prefix, to_prefix = opts.delete("from_date"), opts.delete("to_date")
        from_prefix ||= (previous_month_domain =~ /#{BASE_DOMAIN}([0-9]{6})/; "#{$1}01")
        to_prefix ||= (this_month_domain =~ /#{BASE_DOMAIN}([0-9]{6})/; "#{$1}31")

        # First check cache
        # TODO

        sdb = new_sdb_connection
        domains = sdb.list_domains.body["Domains"].select { |domain| domain =~ /#{BASE_DOMAIN}/ }
        return [] if domains.empty?

        # Get records in a date range
        records = read_range_sdb(from_prefix, to_prefix)

        # Filter records
        opts.each do |key,val|
          next unless val and not val.empty?

          case key
          when /_(id|href|rev)$/
            records.reject! { |uid,hsh| hsh[key] != val }
          when "tags"
            records.reject! { |uid,hsh| !val.include?(hsh[key]) }
          else
            records.reject! { |uid,hsh| hsh[key] !~ /#{val}/ }
          end
        end
        return [] if records.empty?

        # Cache
        to_cache = records.reject { |record| record["status"] !~ /^(cancelled|failed|passed)$/ }
        unless to_cache.empty?
          cache = read_cache
          cache.deep_merge(to_cache.map { |record| [record.uid, self.new.deep_merge(record)] }.to_h)
          write_cache(cache)
        end
        return records.map { |record| self.new.deep_merge(record) }
=begin
var d1 = [ [0,10], [1,20], [2,80], [3,70], [4,60] ];
var d2 = [ [0,30], [1,25], [2,50], [3,60], [4,95] ];
var d3 = [ [0,50], [1,40], [2,60], [3,95], [4,30] ];

var data = [{
              label: "Goal",
              color: "rgb(0,0,0)",
              data: d1,
              spider: {
                show: true,
                lineWidth: 12
              }
            },
            {
              label: "Complete",
              color: "rgb(0,255,0)",
              data: d3,
              spider: {
                show: true
              }
            }];

        ret = {"autocomplete_values" => {}, "raw_data" => []}
        domains.each do |domain|
          # TODO Return in the above format
        end
=end
      end

      #####################################################
      #                      NOTE                         #
      #####################################################
      # This function accepts GrinderJobs, not API::Jobs. #
      # It should not be called from the REST API. Sorry  #
      # for the confusion. -twrodriguez                   #
      #####################################################
      def self.create(opts={})
        unless opts["jobs"].is_a?(Array) && opts["jobs"].unanimous? { |j| VirtualMonkey::GrinderJob === j }
          raise ArgumentError.new("Report.create() requires an Array of GrinderJobs")
        end
        unless opts["log_started"].is_a?(String)
          raise ArgumentError.new("Report.create() requires a 'log_started' string")
        end
        report_url = VirtualMonkey::API::Report.update_s3(opts["jobs"], opts["log_started"])
        VirtualMonkey::API::Report.update_sdb(opts["jobs"]) if opts["report_metadata"]

        # Write to cache
        to_cache = opts["jobs"].reject { |job| job.metadata["status"] !~ /^(cancelled|failed|passed)$/ }
        unless to_cache.empty?
          cache = read_cache
          cache.deep_merge(to_cache.map { |job| [job.metadata["uid"], self.new.deep_merge(job.metadata)] }.to_h)
          write_cache(cache)
        end

        opts["jobs"].map { |job| job.metadata["uid"] }
      end

      def self.get(uid)
        uid = normalize_uid(uid)

        # First check local cache
        record = self.from_json_file(TEMP_STORE, uid)
        return record if record

        # Next check SimpleDB
        record = read_single_record_sdb(uid)
        raise IndexError.new("#{self} #{uid} not found") unless record
        return self.new.deep_merge(record)
      end

      def self.delete(uid)
        not_implemented # TODO - later
      end

      def self.details(uid)
        # This will grab the contents of the logs from s3
        not_implemented # TODO - later
      end

      #
      # Unexposed API
      #
      public

      def self.update_s3(jobs, log_started)
        # A small proc that creates the arguments to put_object()
        upload_args = proc do |bucket, log_started, filename|
          content = `file -ib "#{filename}"`.split(/;/).first
          [
            bucket,
            "#{log_started}/#{File.basename(filename)}",
            IO.read(filename),
            {'x-amz-acl' => 'public-read', 'Content-Type' => content.chomp}
          ]
        end

        # Initialize Variables
        s3 = new_s3_connection
        passed = jobs.select { |s| s.status == 0 }
        failed = jobs.select { |s| s.status != 0 && s.status != nil }
        running = jobs.select { |s| s.status == nil }
        report_on = jobs.select { |s| s.status == 0 || (s.status != 0 && s.status != nil) }
        bucket_name = Fog.credentials[:s3_bucket] || "virtual_monkey"
        local_log_dir = File.join(VirtualMonkey::LOG_DIR, log_started)

        index = ERB.new(File.read(File.join(VirtualMonkey::LIB_DIR, "index.html.erb")))
        index_html_file = File.join(local_log_dir, "index.html")
        File.open(index_html_file, 'w') { |f| f.write(index.result(binding)) }

        ## upload to s3
        unless directory = s3.directories.detect { |d| d.key == bucket_name }
          directory = s3.directories.create(:key => bucket_name)
        end
        raise "FATAL: Could not create directory. Check log files locally in #{local_log_dir}" unless directory

        begin
          s3.put_object(*upload_args[bucket_name, log_started, index_html_file])
        rescue Excon::Errors::ServiceUnavailable
          warn "Got \"ServiceUnavailable\", retrying..."
          sleep 5
          retry
        rescue Errno::ENOENT, Errno::EBADF => e
          warn "Got \"#{e.message}\", retrying..."
          sleep 1
          retry
        end
        s3_base_url = "http://s3.amazonaws.com/#{bucket_name}"
        s3_index_url = "#{s3_base_url}/#{log_started}/index.html"

        report_on.each do |job|
          job.metadata["report_page"] = s3_index_url
          job.metadata["status"] = (job.status == 0 ? "passed" : "failed") if job.status
          begin
            [job.logfile, job.rest_log].each { |log|
              s3_put_args = upload_args[bucket_name, log_started, log]
              s3.put_object(*s3_put_args)
              job.metadata["logs"] ||= []
              job.metadata["logs"] |= ["#{s3_base_url}/#{s3_put_args[1]}"]
            }
            ([job.err_log] + job.other_logs).each { |log|
              if File.exists?(log)
                s3_put_args = upload_args[bucket_name, log_started, log]
                s3.put_object(*s3_put_args)
                job.metadata["logs"] ||= []
                job.metadata["logs"] |= ["#{s3_base_url}/#{s3_put_args[1]}"]
              end
            }
          rescue Excon::Errors::ServiceUnavailable
            warn "Got \"ServiceUnavailable\", retrying..."
            sleep 5
            retry
          rescue Errno::ENOENT, Errno::EBADF => e
            warn "Got \"#{e.message}\", retrying..."
            sleep 1
            retry
          end
        end

        ## Return report url
        return s3_index_url
      end

      def self.update_sdb(jobs)
        ## upload to sdb
        sdb = new_sdb_connection
        begin
          ensure_domain_exists
          current_items = sdb.select("SELECT * from #{this_month_domain}").body["Items"]
          data = {}
          jobs.each do |job|
            if current_items[job.metadata["uid"]]
              # Only need to update status and logs
              if current_items[job.metadata["uid"]]["status"] != job.metadata["status"]
                data[job.metadata["uid"]] = {
                  "status" => job.metadata["status"],
                  "logs" => job.metadata["logs"]
                }
              end
            else
              # Send all metadata
              data[job.metadata["uid"]] = job.metadata
            end
          end
          sdb.batch_put_attributes(this_month_domain, data)
        rescue Excon::Errors::ServiceUnavailable
          warn "Got \"ServiceUnavailable\", retrying..."
          sleep 5
          retry
        rescue Exception => e
          warn "Got \"#{e.message}\" from #{e.backtrace.join("\n")}"
        end
        nil
      end
    end
  end
end
