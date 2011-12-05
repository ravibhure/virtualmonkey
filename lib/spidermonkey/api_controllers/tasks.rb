module VirtualMonkey
  module API
    class Task < VirtualMonkey::API::BaseResource
      PATH = "#{VirtualMonkey::API::ROOT}/tasks".freeze
      ContentType = "application/vnd.rightscale.virtualmonkey.task"
      CollectionContentType = ContentType + ";type=collection"
      TEMP_STORE = File.join("", "tmp", "spidermonkey_tasks.json").freeze
      SDB_STORE = "virtualmonkey_tasks".freeze

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
          "command",
          "options",
          "schedule",
          "name",
          "uid",
        ]
      end
      private_class_method :fields

      #
      # Constructor
      #
      public

      def initialize(*args, &block)
        super(*args, &block)
        task_uid = Time.now.strftime("%Y%m%d%H%M%S#{rand(1000000)}")
        self.actions |= [
          {"rel" => "save"},
          {"rel" => "purge"},
          {"rel" => "schedule"},
          {"rel" => "start"},
        ]
        self.links |= [
          {"href" => self.class::PATH + "/#{task_uid}",
           "rel" => "self"},
        ]
        self["uid"] = task_uid
        self
      end

      #
      # API
      #
      public

      def self.index
        read_cache.map { |uid,item_hash| new.deep_merge(item_hash) }
      end

      def self.create(opts={})
        # Check for required Arguments
        raise ArgumentError.new("#{PATH} requires a command") unless opts["command"].is_a?(String)

        # Sanitize
        opts &= (fields | CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s })

        # Read, Create, and Write record
        cache = read_cache
        new_record = self.new.deep_merge(opts)
        cache[new_record.uid] = new_record
        write_cache(cache)

        return new_record.uid
      end

      def self.get(uid)
        uid = normalize_uid(uid)
        record = self.from_json_file(TEMP_STORE, uid)
        raise IndexError.new("#{self} #{uid} not found") unless record
        record
      end

      def self.update(uid, opts={})
        uid = normalize_uid(uid)
        # Sanitize
        opts &= (fields | CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s })
        opts["updated_at"] = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")

        # Read and update
        cache = read_cache
        cache[uid].deep_merge!(opts)
        write_cache(cache)
      end

      def self.delete(uid)
        uid = normalize_uid(uid)
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache.delete(uid)
        write_cache(cache)
        nil
      end

      def self.save(uid)
        uid = normalize_uid(uid)
        # Saves to SimpleDB NOTE: don't save "schedule" field
        not_implemented # TODO - later
      end

      def self.purge(uid)
        uid = normalize_uid(uid)
        # Deletes from SimpleDB and Cache
        not_implemented # TODO - later
      end

      def self.schedule(uid, opts={})
        uid = normalize_uid(uid)
        # Linux only for now
        cache = read_cache
        raise IndexError.new("#{self} #{uid} not found") unless cache[uid]

        # Sanitize
        opts &= CronEdit::CronEntry::DEFAULTS.keys.map { |k| k.to_s }
        opts["updated_at"] = Time.now.utc.strftime("%Y/%m/%d %H:%M:%S +0000")
        opts.delete("command")
        cronedit_opts = opts.map { |k,v| [k.to_sym, v] }.to_h

        # Read rest_connection settings
        settings = YAML::load(IO.read(VirtualMonkey::REST_YAML))
        base_url = "https://#{settings[:user]}:#{settings[:pass]}@127.0.0.1"
        path = "#{PATH}/#{uid}/start"
        cronedit_opts[:command] = "curl -x POST #{base_url}#{path}"

        crontab = File.join("", "etc", "crontab")

        ct = CronEdit::FileCrontab.new(crontab, crontab)
        ct.add("#{uid}", cronedit_opts)
        ct.commit
        return nil
      end

      def self.start(uid)
        uid = normalize_uid(uid)
        return VirtualMonkey::API::Job.create("task" => uid)
      end
    end
  end
end
