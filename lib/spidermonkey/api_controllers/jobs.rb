module VirtualMonkey
  module API
    class Job < VirtualMonkey::API::BaseResource
      PATH = "#{VirtualMonkey::API::ROOT}/jobs".freeze
      TEMP_STORE = File.join("", "tmp", "spidermonkey_jobs.json").freeze
      DAEMONS_OPTIONS = {
        :backtrace => true,
        :multiple => true,
        :log_output => true,
        :log_dir => File.join("", "tmp", "spidermonkey_jobs"),
#        :stop_proc => nil,
      }.freeze

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
          "task",
          "priority",
        ]
      end
      private_class_method :fields

      #
      # Constructor
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        job_uid = Time.now.strftime("%Y%m%d%H%M%S#{rand(1000000)}")
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
        if opts["command"] and not opts["task"]
          opts["task"] = VirtualMonkey::API::Task.create(opts.dup)
        end
        raise ArgumentError.new("#{PATH} requires a parent task or a command") unless opts["task"]
        parent_task = VirtualMonkey::API::Task.get(opts["task"])
        task_uri = VirtualMonkey::API::Task::PATH + "/#{opts["task"]}"
        raise IndexError.new("#{task_uri} not found") unless parent_task
        parent_task["options"] ||= []

        # Sanitize
        opts &= fields

        # Normalize Priority
        opts["priority"] ||= 5
        opts["priority"] = [[opts["priority"], 10].min, 1].max unless (1..10) === opts["priority"]

        new_record = self.new.deep_merge(opts)
        new_record.links |= [{"href" => task_uri, "rel" => "task"}]

        # Ensure a Cronjob exists to bump the queue
        crontab = File.join("", "etc", "crontab")
        ct = CronEdit::FileCrontab.new(crontab, crontab)
        unless ct.list["garbage_collection"]
          # Read rest_connection settings
          settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))
          base_url = "https://#{settings[:user]}:#{settings[:pass]}@127.0.0.1"
          path = "#{PATH}/garbage_collect"
          ct.add("garbage_collection", :minute => "*/1", :command => "curl -x POST #{base_url}#{path}")
          ct.commit
        end

        # Create record
        if VirtualMonkey::daemons.length < (VirtualMonkey::config[:max_jobs] || 2)
          app = Daemons.call(DAEMONS_OPTIONS.merge(:app_name => "SpiderMonkey-#{new_record.uid}")) do
            VirtualMonkey::Command.__send__(parent_task["command"], *parent_task["options"])
          end
          new_record["daemon"] = app
          new_record["status"] = "running"
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
        # First try in running daemons
        record = VirtualMonkey::daemons.detect { |d| d.uid == uid }
        if record
          if record["daemon"].running?
            record["daemon"].stop
            record["status"] = "failed"
          else
            record["status"] = "finished" #TODO: Detect whether passed or failed
          end
          record.delete("daemon")

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
          new_q << VirtualMonkey::daemon_queue.pop until VirtualMonkey::daemon_queue.size == 0
          new_q.reject! { |h| h.uid == record.uid }
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
        VirtualMonkey::daemons.reject! { |d| d["status"] !~ /^(pending|running)$/ }
        ((VirtualMonkey::config[:max_jobs] || 2) - VirtualMonkey::daemons.size).times do |i|
          job = VirtualMonkey::daemon_queue.pop
          if job
            parent_task = VirtualMonkey::API::Task.get(job.links.to_h("rel", "href")["task"])
            app = Daemons.call(DAEMONS_OPTIONS.merge(:app_name => "SpiderMonkey-#{job.uid}")) do
              VirtualMonkey::Command.__send__(parent_task["command"], *parent_task["options"])
            end
            job["daemon"] = app
            job["status"] = "running"
            VirtualMonkey::daemons << job
          end
        end
        return nil
      end
    end
  end
end
