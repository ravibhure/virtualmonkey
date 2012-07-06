module VirtualMonkey
  module API
    class Report < VirtualMonkey::API::BaseResource
      extend VirtualMonkey::API::StandardSimpleDBHelpers
      PATH = "#{VirtualMonkey::API::ROOT}/reports".freeze
      ContentType = "application/vnd.rightscale.virtualmonkey.report"
      CollectionContentType = ContentType + ";type=collection"
      TEMP_STORE = File.join("", "tmp", "spidermonkey_reports.json").freeze
      BASE_DOMAIN = "virtualmonkey_report_metadata".freeze
      S3_HOST = "s3.amazonaws.com"
      S3_SCHEME = "http"

      #
      # Helper Methods
      #
      private

      def self.read_cache
        JSON::parse(IO.read(TEMP_STORE))
      rescue Errno::ENOENT, JSON::ParserError
        File.open(TEMP_STORE, "w") { |f| f.write("{}") }
        return {}
      rescue Errno::EBADF, IOError
        sleep 0.1
        retry
      end
      private_class_method :read_cache

      def self.write_cache(json_hash)
        File.open(TEMP_STORE, "w") { |f| f.write(json_hash.to_json) }
      rescue Errno::EBADF, IOError
        sleep 0.1
        retry
      end
      private_class_method :write_cache

      def self.fields
        @@fields ||= [
          "user_email",
          "user_name",
          "mci_name",
          "mci_href",
          "mci_os",
          "mci_os_version",
          "mci_arch",
          "mci_rightlink",
          #"mci_hypervisor",
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
          "annotation",
        ]
      end
      private_class_method :fields

      def self.update_fields
        @@update_fields ||= [
          "annotation",
          "tags",
          "user",
        ]
      end
      private_class_method :update_fields

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

      def self.delete_single_record_sdb(uid)
        uid = normalize_uid(uid)
        sdb = new_sdb_connection
        domain_to_check = BASE_DOMAIN + uid[0..5]
        unless sdb.list_domains.body["Domains"].include?(domain_to_check)
          raise IndexError.new("#{self} #{uid} not found")
        end
        sdb.delete_attributes(domain_to_check, uid)
      end

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
            # Since all attributes in SDB have an array of values, get rid of the array
            # if it is only of length 1
            current_items.each do |key,hsh|
              current_items[key].each { |k,v|
                current_items[key][k] = v.first if v.is_a?(Array) && v.length < 2
              }
            end
          rescue Excon::Errors::ServiceUnavailable
            warn "Got \"ServiceUnavailable\", retrying..."
            sleep 2
            retry
          end
          # Reject by started_at timestamps
          if domain == start_domain
            current_items.reject! { |key,hsh| hsh["started_at"] < start_stamp }
          end
          if domain == end_domain
            current_items.reject! do |key,hsh|
              hsh["started_at"] > end_stamp && hsh["started_at"] !~ /^#{start_stamp}/
            end
          end
          records += current_items.values
        end

        # Cache
        to_cache = records.reject { |record| record["status"] !~ /^(cancelled|failed|passed)$/ }
        unless to_cache.empty?
          cache = read_cache
          cache.deep_merge(to_cache.map { |record| [record["uid"], self.new.deep_merge(record)] }.to_h)
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
        y, m = (current_domain =~ /#{BASE_DOMAIN}([0-9]{4})([0-9]{2})/; [$1.to_i, $2.to_i]) if current_domain

        y -= ((m == 1) ? 1 : 0)
        m = ((m + 10) % 12) + 1
        [BASE_DOMAIN, y, ("%02d" % m)].join("")
      end
      private_class_method :previous_month_domain

      #
      # Constructor and Instance Methods
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        report_uid = Time.now.strftime("%Y%m%d%H%M%S#{[rand(1000000).to_s].pack('m').chomp}")
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

        records = []

        # First check cache
        if from_prefix && to_prefix
          from_num, to_num = from_prefix.to_i, to_prefix.to_i
          cache = read_cache
          # We can only save ourselves from SimpleDB if we have the full range
          if cache.keys.min[0..7] < from_prefix && to_prefix < Time.now.strftime("%Y%m%d")
            records = cache.values.select { |r| (from_num..to_num) === r["uid"][0..7].to_i }
          end
        end

        # Then pull from SimpleDB if we didn't have the full range
        if records.empty?
          from_prefix ||= (previous_month_domain =~ /#{BASE_DOMAIN}([0-9]{6})/; "#{$1}01")
          to_prefix ||= (this_month_domain =~ /#{BASE_DOMAIN}([0-9]{6})/; "#{$1}31")

          sdb = new_sdb_connection
          domains = sdb.list_domains.body["Domains"].select { |domain| domain =~ /#{BASE_DOMAIN}/ }
          return [] if domains.empty?

          # Get records in a date range
          records = read_range_sdb(from_prefix, to_prefix)
        end

        # Filter records
        opts.each do |key,val|
          next unless val and not val.empty?

          case key
          when /_(id|href|rev)$/
            records.reject! { |hsh| hsh[key] != val }
          when "tags"
            records.reject! { |hsh| !val.include?(hsh[key]) }
          else
            records.reject! { |hsh| hsh[key] !~ /#{val}/ }
          end
        end
        return [] if records.empty?

        # Cache
        to_cache = records.reject { |record| record["status"] !~ /^(cancelled|failed|passed)$/ }
        unless to_cache.empty?
          cache = read_cache
          cache.deep_merge(to_cache.map { |record| [record["uid"], self.new.deep_merge(record)] }.to_h)
          write_cache(cache)
        end
        return records.map { |record| self.new.deep_merge(record) }
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
        record ||= read_single_record_sdb(uid)
        raise IndexError.new("#{self} #{uid} not found") unless record
        return self.new.deep_merge(record)
      end

      def self.update(uid, opts={})
        uid = normalize_uid(uid)

        # Sanitize
        opts &= update_fields

        # Write to SimpleDB
        record = get(uid).deep_merge(opts.merge("uid" => uid))
        VirtualMonkey::API::Report.update_sdb(record)

        # Update Cache
        cache = read_cache
        cache[uid].deep_merge(record)
        write_cache(cache)
        true
      end

      def self.delete(uid)
        uid = normalize_uid(uid)

        delete_single_record_sdb(uid)
        cache = read_cache
        cache.delete(uid)
        write_cache(cache)
      end

      def self.details(uid)
        # This will grab the contents of the logs from s3
        uid = normalize_uid(uid)

        record = get(uid)
        raise NameError.new("#{self} doesn't have any logs") unless Array === record["logs"]
        raise NameError.new("#{self} doesn't have a report_page") unless record["report_page"]
        return record["logs"].map_to_h do |log_url|
          uri = URI.parse(log_url)
          unless uri.absolute?
            uri = URI.parse(record["report_page"])
            uri.set_scheme(S3_SCHEME)
            uri.set_host(S3_HOST)
            uri.set_path = (uri.path.split("/")[0..-2] << log_url.split("/").last).join("/")
          end
          RestClient.get(uri.to_s)
        end
      end

      def self.autocomplete(date_begin=nil, date_end=nil)
        opts = {}
        opts.merge!("from_date" => date_begin, "to_date" => date_end) if date_begin && date_end
        listings = index(opts)

        ret_hsh = {}
        fields.each do |field|
          ret_hsh[field] ||= []
          ret_hsh[field] |= listings.map { |record| record[field] }.compact
        end

        ret_hsh.each { |field,ary| ret_hsh[field].sort! }

        return ret_hsh
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
            {'x-amz-acl' => 'public-read', 'Content-Type' => (File.extname(filename) == ".log" ? 'text/plain' : content.chomp)}
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

        index = ERB.new(File.read(File.join(VirtualMonkey::API_CONTROLLERS_DIR, "report.html.erb")))
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

      # This method can either accept VirtualMonkey::GrinderJobs or VirtualMonkey::API::Daemon
      def self.update_sdb(*jobs)
        jobs.flatten!
        data_ary = []
        if jobs.reduce(true) { |b,j| b && (VirtualMonkey::GrinderJob === j) }
          data_ary = jobs.map { |j| j.metadata }
        elsif jobs.reduce(true) { |b,j| b && (VirtualMonkey::API::Daemon === j) }
          data_ary = jobs.metadata.map { |deploy_id,mdata| mdata }
        elsif jobs.reduce(true) { |b,j| b && (self === j) }
          data_ary = jobs
        else
          raise TypeError.new("can't convert #{jobs.map { |j| j.class }} to Array of GrinderJobs")
        end

        ## upload to sdb
        sdb = new_sdb_connection
        begin
          ensure_domain_exists
          current_items = sdb.select("SELECT * from #{this_month_domain}").body["Items"]
          data = {}
          replace_data = {}
          data_ary.each do |job_metadata|
            next unless Hash === job_metadata
            report = self.new.deep_merge(job_metadata)
            report -= ["links", "actions"]
            if current_items[report["uid"]]
              # Only need to update stuff that has changed
              data[report["uid"]] = report.reject { |key,val| val == current_items[report["uid"]][key] }
              data[report["uid"]]["updated_at"] = self.new["updated_at"]
              replace_data[job_metadata["uid"]] = data[report["uid"]].keys
            else
              # Send all metadata that is a string (no arrays like "links" or "actions")
              data[report["uid"]] = report
              replace_data[report["uid"]] = report.keys
            end
          end

          # Partition Data into 25-item chunks
          data.chunk(25).each do |chunked_data|
            begin
              sdb.batch_put_attributes(this_month_domain, chunked_data, (replace_data & chunked_data.keys))
            rescue Excon::Errors::ServiceUnavailable
              warn "Got \"ServiceUnavailable\", retrying..."
              sleep 5
              retry
            end
          end
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
