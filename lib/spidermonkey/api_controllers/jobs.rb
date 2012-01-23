module VirtualMonkey
  module API
    class Job < VirtualMonkey::API::BaseResource
      PATH = "#{VirtualMonkey::API::ROOT}/jobs".freeze
      ContentType = "application/vnd.rightscale.virtualmonkey.job"
      CollectionContentType = ContentType + ";type=collection"
      TEMP_STORE = File.join("", "tmp", "spidermonkey_jobs.json").freeze

      #
      # Helper Methods
      #
      private

      def self.read_cache
        JSON::parse(IO.read(TEMP_STORE))
      rescue Errno::ENOENT, JSON::ParserError
        File.open(TEMP_STORE, "w") { |f| f.write("{}") }
        return {}
      rescue Errno::EBADF
        sleep 0.1
        retry
      end
      private_class_method :read_cache

      def self.write_cache(json_hash)
        File.open(TEMP_STORE, "w") { |f| f.write(json_hash.to_json) }
      end
      private_class_method :write_cache

      def self.fields
        # These fields are commented because they are placed in the "links" field
        # by the time they are sanitized
        [
#          "parent_task",
          "priority",
          "user",
#          "callback_task",
        ]
      end
      private_class_method :fields

      def self.daemon_child(&block)
        pid = Process.fork do
          #$stdout = File.new("/dev/null", "w")
          #$stderr = File.new("/dev/null", "w")
          yield
        end
        thread = Process.detach(pid)
        [pid, thread]
      end
      private_class_method :daemon_child

      #
      # Constructor
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        job_uid = Time.now.strftime("%Y%m%d%H%M%S#{[rand(1000000).to_s].pack('m').chomp}")
        self.actions |= [
        ]
        self.links |= [
          {"href" => self.class::PATH + "/#{job_uid}",
           "rel" => "self"},
        ]
        self["uid"] = job_uid
        self
      end

      #
      # API
      #
      public

      def self.index
        VirtualMonkey::daemons + VirtualMonkey::daemon_queue.to_a
      end

      def self.create(opts={})
        # Check for required Arguments
        if opts["command"] and not opts["parent_task"]
          opts["parent_task"] = VirtualMonkey::API::Task.create(opts.dup)
        end
        raise ArgumentError.new("#{PATH} requires a parent task or a command") unless opts["parent_task"]
        parent_task = VirtualMonkey::API::Task.get(opts["parent_task"])
        task_uri = VirtualMonkey::API::Task::PATH + "/#{normalize_uid(opts["parent_task"])}"
        raise IndexError.new("#{task_uri} not found") unless parent_task
        parent_task["options"] ||= []

        callback_task = nil
        if opts["callback_task"]
          callback_task = VirtualMonkey::API::Task.get(opts["callback_task"])
          callback_uri = VirtualMonkey::API::Task::PATH + "/#{normalize_uid(opts["callback_task"])}"
          raise IndexError.new("#{callback_uri} not found") unless callback_task
        end

        # Sanitize
        opts &= fields

        # Normalize Priority
        opts["priority"] ||= 5
        opts["priority"] = [[opts["priority"], 10].min, 1].max unless (1..10) === opts["priority"]

        # Get user data
        opts["user"] ||= rest_config_yaml[:user]

        new_record = self.new.deep_merge(opts)
        new_record.links |= [{"href" => task_uri, "rel" => "parent"}]
        new_record.links |= [{"href" => callback_task.uri, "rel" => "callback"}] if callback_task
        new_record["name"] = parent_task["name"]

        if File.writable?(VirtualMonkey::SYS_CRONTAB)
          # Ensure a Cronjob exists to bump the queue
          crontab = VirtualMonkey::SYS_CRONTAB
          ct = CronEdit::FileCrontab.new(crontab, crontab)
          unless ct.list["garbage_collection"]
            # Read rest_connection settings
            settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))
            base_url = "https://#{settings[:user]}:#{settings[:pass]}@127.0.0.1"
            path = "#{PATH}/garbage_collect"
            ct.add("garbage_collection", :minute => "*/1", :command => "curl -x POST #{base_url}#{path}")
            ct.commit
          end
        else
          STDERR.puts("File #{VirtualMonkey::SYS_CRONTAB} isn't writable! You need to POST to '#{PATH}/garbage_collect' manually.")
        end

        # Create record
        if VirtualMonkey::daemons.length < VirtualMonkey::config[:max_jobs]
          pid, app = daemon_child do
            args = parent_task["options"].map do |k,v|
              opt = "--#{k.gsub(/_/, '-')}"
              opt += " #{[v].flatten.join(" ")}" unless v.nil? || v.empty? || v.is_a?(Boolean)
            end
            args |= ["--yes"]
            if parent_task['command'] =~ /^run|troop|clone$/
              args |= ["--report-metadata"]
            end
            puts "\nlaunching command: #{parent_task['command']} #{args.join(' ')}\n\n"
            VirtualMonkey::Command.__send__(parent_task["command"], args.join(" "))
            exit 0
          end
          new_record.merge!("daemon" => app, "pid" => pid, "status" => "running")
          VirtualMonkey::daemons << new_record
        else
          new_record["status"] = "pending"
          VirtualMonkey::daemon_queue.push(new_record, opts["priority"])
        end
        return new_record.uid
      end

      def self.get(uid)
        uid = normalize_uid(uid)
        record = VirtualMonkey::daemons.detect { |d| d.uid == uid }
        record ||= VirtualMonkey::daemon_queue.detect { |d| d.uid == uid }
        record ||= self.from_json_file(TEMP_STORE, uid)
        raise IndexError.new("#{self} #{uid} not found") unless record
        record
      end

      def self.delete(uid)
        uid = normalize_uid(uid)
        # NOTE: this cancel function will cancel the callbacks as well

        # First try in running daemons
        record = VirtualMonkey::daemons.detect { |d| d.uid == uid }
        if record
          if record["daemon"] && record["daemon"].alive?
            record["daemon"].kill
            record["status"] = "cancelled"
            unless [0,1, $$].include?(record["pid"].to_i)
              Process.kill("TERM", record["pid"].to_i)
            end
          elsif record["daemon"]
            record["status"] = (record["daemon"].value.exitstatus == 0 ? "passed" : "failed")
          else
            record["status"] = "unknown"
          end
          record.delete("daemon")
          record.delete("pid")

          cache = read_cache
          cache[record.uid] = record
          write_cache(cache)

          garbage_collect()
          return nil
        end

        # Next try in daemon queue
        record = VirtualMonkey::daemon_queue.to_a.detect { |d| d.uid == uid }
        if record
          record["status"] = "cancelled"
          new_q = []
          until VirtualMonkey::daemon_queue.size == 0
            h = VirtualMonkey::daemon_queue.pop
            new_q << h unless h.uid == record.uid
          end
          new_q.each { |h| VirtualMonkey::daemon_queue.push(h, h["priority"]) }

          cache = read_cache
          cache[record.uid] = record
          write_cache(cache)
          return nil
        end

        # Finally try in completed cache
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache.delete(uid)
        write_cache(cache)
        nil
      end

      def self.garbage_collect
        cache = read_cache
        callback_jobs = []
        VirtualMonkey::daemons.each do |record|
          if record["daemon"] and not record["daemon"].alive?
            record["status"] = (record["daemon"].value.exitstatus == 0 ? "passed" : "failed")
            record.delete("daemon")
            record.delete("pid")
            callback_jobs << record if record.links.to_h("rel", "href")["callback"]

            cache[record.uid] = record
          end
        end
        write_cache(cache)
        VirtualMonkey::daemons.reject! { |d| d["status"] !~ /^(pending|running)$/ }

        # Callback tasks take priority
        callback_jobs.each do |record|
          parent_uid = record.uid
          callback_uri = record.links.to_h("rel", "href")["callback"]
          status = record["status"]
          next_task_href = VirtualMonkey::API::Task.get_next_subtask_href(parent_uid, callback_uri, status)
          opts = {"parent_task" => next_task_href, "callback_task" => callback_uri, "user" => record["user"]}
          self.create(opts) if next_task_href
        end

        # Replace any vacancies with jobs from the queue
        (VirtualMonkey::config[:max_jobs] - VirtualMonkey::daemons.size).times do |i|
          job = VirtualMonkey::daemon_queue.pop
          if job
            parent_task = VirtualMonkey::API::Task.get(job.links.to_h("rel", "href")["parent"])
            pid, thread = daemon_child do
              VirtualMonkey::Command.__send__(parent_task["command"], *parent_task["options"])
            end
            job.merge!("daemon" => thread, "pid" => pid, "status" => "running")
            VirtualMonkey::daemons << job
          end
        end
        return nil
      end
    end
  end
end
