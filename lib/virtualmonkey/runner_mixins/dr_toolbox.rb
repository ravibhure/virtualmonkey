module VirtualMonkey
  module Mixin
    module DrToolbox
  
      # Stolen from ::EBS need to consolidate or dr_toolbox needs a terminate script to include ::EBS instead
      # take the lineage name, find all snapshots and sleep until none are in the pending state.
      def wait_for_snapshots
        timeout=1500
        step=10
        while timeout > 0
          puts "Checking for snapshot completed"
          snapshots =find_snapshots
          status = snapshots.map { |x| x.aws_status } 
          break unless status.include?("pending")
          sleep step
          timeout -= step
        end
        raise "FATAL: timed out waiting for all snapshots in lineage #{@lineage} to complete" if timeout == 0
      end

      # Find all snapshots associated with this deployment's lineage
      def find_snapshots
        s = @servers.first
        unless @lineage
          kind_params = s.parameters
          @lineage = kind_params['db/backup/lineage'].gsub(/text:/, "")
        end
        if s.cloud_id.to_i < 10
          snapshots = Ec2EbsSnapshot.find_by_cloud_id(s.cloud_id).select { |n| n.tags.include?("rs_backup:lineage=#{@lineage}") }
        elsif s.cloud_id.to_i == 232
          snapshot = [] # Ignore Rackspace, there are no snapshots
        else
          snapshots = McVolumeSnapshot.find_all(s.cloud_id).select { |n| n.tags(true).include?("rs_backup:lineage=#{@lineage}") }
        end
        snapshots
      end

      def find_snapshot_timestamp(server, provider = :volume)
        case provider
        when :volume
          if server.cloud_id.to_i != 232
            last_snap = find_snapshots.last
            last_snap.tags(true).detect { |t| t =~ /timestamp=(\d+)$/ }
            timestamp = $1
          else #Rackspace uses cloudfiles object store
            cloud_files = Fog::Storage.new(:provider => 'Rackspace')
            if dir = cloud_files.directories.detect { |d| d.key == @container }
              dir.files.first.key =~ /-([0-9]+\/[0-9]+)/
              timestamp = $1
            end
          end
        when "S3"
          s3 = Fog::Storage.new(:provider => 'AWS')
          if dir = s3.directories.detect { |d| d.key == @secondary_container }
            dir.files.first.key =~ /-([0-9]+\/[0-9]+)/
            timestamp = $1
          end
        when "CloudFiles"
          cloud_files = Fog::Storage.new(:provider => 'Rackspace')
          if dir = cloud_files.directories.detect { |d| d.key == @secondary_container }
            dir.files.first.key =~ /-([0-9]+\/[0-9]+)/
            timestamp = $1
          end
        else
          raise "FATAL: Provider #{provider.to_s} not supported."
        end
        return timestamp
      end
  
      def set_variation_lineage
        @lineage = "testlineage#{resource_id(@deployment)}"
        @deployment.set_input("block_device/lineage", "text:#{@lineage}")
        @servers.each do |server|
          server.set_inputs({"block_device/lineage" => "text:#{@lineage}"})
        end
      end
  
      def set_variation_container
        @container = "testlineage#{resource_id(@deployment)}"
        @deployment.set_input("block_device/storage_container", "text:#{@container}")
        @servers.each do |server|
          server.set_inputs({"block_device/storage_container" => "text:#{@container}"})
        end
      end
=begin  
      # Pick a storage_type depending on what cloud we're on.
      def set_variation_storage_type(storage=nil)
        cid = VirtualMonkey::Toolbox::determine_cloud_id(s_one)
        if storage
          @storage_type = storage
        elsif cid == 232 # rackspace
          @storage_type = "ros"
        else
          #pick = rand(100000) % 2
          #if pick == 1
          #  @storage_type = "ros"
          #else
            @storage_type = "volume"
          #end
        end
        puts "STORAGE_TYPE: #{@storage_type}"
        @storage_type = ENV['STORAGE_TYPE'] if ENV['STORAGE_TYPE']
   
        @deployment.set_input("block_device/storage_type", "text:#{@storage_type}")
        @servers.each do |server|
          server.set_inputs({"block_device/storage_type" => "text:#{@storage_type}"})
        end
      end
=end
      def set_variation_mount_point(mount_point = '/mnt/storage')
        @mount_point = mount_point

        @deployment.set_input('block_device/mount_dir', "text:#{@mount_point}")
        @servers.each do |server|
          server.set_inputs({'block_device/mount_dir' => "text:#{@mount_point}"})
        end
      end
  
      def test_volume_backup
        run_script("setup_block_device", s_one)
        probe(s_one, "touch /mnt/storage/monkey_was_here")
        run_script("do_backup", s_one)
        wait_for_snapshots
        run_script("do_force_reset", s_one)
        run_script("do_restore", s_one)
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end

      def test_s3
        run_script("do_force_reset", s_one)
        sleep 10
        run_script("setup_block_device", s_one)
        sleep 10
        probe(s_one, "dd if=/dev/urandom of=/mnt/storage/monkey_was_here bs=4M count=200")
        sleep 10
        run_script("do_backup_s3", s_one)
        sleep 10
        run_script("do_force_reset", s_one)
        sleep 10
        run_script("do_restore_s3", s_one)
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
        run_script("do_force_reset", s_one)
        sleep 10
        run_script("do_restore_s3", s_one, {"block_device/timestamp_override" => "text:#{find_snapshot_timestamp(:s3)}" })
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end

      def test_volume
        run_script("do_force_reset", s_one)
        sleep 10
        run_script("setup_block_device", s_one)
        probe(s_one, "dd if=/dev/urandom of=#{@mount_point}/monkey_was_here bs=4M count=100")
        sleep 10
        run_script("do_backup", s_one)
        sleep 10
        run_script("do_force_reset", s_one)
        sleep 10
        run_script("do_restore", s_one)
        probe(s_one, "ls #{@mount_point}") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
        # Needs test implemented for euca and cdc
        run_script("do_force_reset", s_one)
        
        run_script("do_restore", s_one, {"block_device/timestamp_override" => "text:#{find_snapshot_timestamp(:ebs)}" })
        probe(s_one, "ls #{@mount_point}") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end

      def cleanup_snapshots
        find_snapshots.each do |snap|
          snap.destroy
        end
      end

      def cleanup_volumes
        @servers.each do |server|
          unless ["stopped", "pending", "inactive"].include?(server.state)
            run_script("do_force_reset", server)
          end
        end
      end

      def test_ebs
        #run_script("do_force_reset", s_one)
        #sleep 10
       run_script("setup_block_device", s_one)
       probe(s_one, "dd if=/dev/urandom of=/mnt/storage/monkey_was_here bs=4M count=100")
       run_script("do_backup_volume", s_one)
# EBS freight-train is buggy if you move too quickly through here
       sleep 30
       run_script("do_force_reset", s_one)
       sleep 30
# Wait for snapshots all to have completed (necessary)
       wait_for_snapshots
       run_script("do_restore_volume", s_one)
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
# sleep (be nice)
       sleep 30
       run_script("do_force_reset", s_one)
       sleep 30
# ok, thanks for sleeping
       run_script("do_restore_volume", s_one, {"block_device/timestamp_override" => "text:#{find_snapshot_timestamp(:ebs)}" })
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end
  
      def test_cloud_files
      # run_script("do_force_reset", s_one)
      #  sleep 10
       run_script("setup_block_device", s_one)
        sleep 10
        probe(s_one, "dd if=/dev/urandom of=/mnt/storage/monkey_was_here bs=4M count=200")
        sleep 10
       run_script("do_backup_cloud_files", s_one)
        sleep 10
       run_script("do_force_reset", s_one)
        sleep 10
       run_script("do_restore_cloud_files", s_one)
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
       run_script("do_force_reset", s_one)
        sleep 10
       run_script("do_restore_cloud_files", s_one, {"block_device/timestamp_override" => "text:#{find_snapshot_timestamp(:cloud_files)}" })
        probe(s_one, "ls /mnt/storage") do |result, status|
          raise "FATAL: no files found in the backup" if result == nil || result.empty?
          true
        end
      end
  
      # pick the right set of tests depending on what cloud we're on
      def test_multicloud
        
      end
  
      def test_continuous_backups_cloud_files
        # Setup Backups for every minute
        opts = {"block_device/cron_backup_hour" => "text:*",
                "block_device/cron_backup_minute" => "text:*"}
       run_script("setup_continuous_backups_cloud_files", s_one, opts)
        cloud_files = Fog::Storage.new(:provider => 'Rackspace')
        # Wait for directory to be created
        sleep 120
        retries = 0
        until dir = cloud_files.directories.detect { |d| d.key == @container }
          retries += 1
          raise "FATAL: Retry count exceeded 10" unless retries < 10
          sleep 30
        end
        # get file count
        count = dir.files.length
        sleep 120
        dir.files.reload
        raise "FATAL: Failed Continuous Backup Enable Test" unless dir.files.length > count
        # Disable cron job
       run_script("do_disable_continuous_backups_cloud_files", s_one)
        sleep 120
        count = dir.files.length
        sleep 120
        dir.files.reload
        raise "FATAL: Failed Continuous Backup Disable Test" unless dir.files.length == count
      end
  
      def test_continuous_backups_s3
        # Setup Backups for every minute
        opts = {"block_device/cron_backup_hour" => "text:*",
                "block_device/cron_backup_minute" => "text:*"}
       run_script("setup_continuous_backups_s3", s_one, opts)
        cloud_files = Fog::Storage.new(:provider => 'AWS')
        # Wait for directory to be created
        sleep 120
        retries = 0
        until dir = cloud_files.directories.detect { |d| d.key == @container }
          retries += 1
          raise "FATAL: Retry count exceeded 10" unless retries < 10
          sleep 30
        end
        # get file count
        count = dir.files.length
        sleep 120
        dir.files.reload
        raise "FATAL: Failed Continuous Backup Enable Test" unless dir.files.length > count
        # Disable cron job
       run_script("do_disable_continuous_backups_s3", s_one)
        sleep 120
        count = dir.files.length
        sleep 120
        dir.files.reload
        raise "FATAL: Failed Continuous Backup Disable Test" unless dir.files.length == count
      end
  
      def test_continuous_backups_volume
        # Setup Backups for every minute
        opts = {"block_device/cron_backup_hour" => "text:*",
                "block_device/cron_backup_minute" => "text:*"}
       run_script("setup_continuous_backups_volume", s_one, opts)
        # Wait for snapshots to be created
        sleep 300
        retries = 0
        snapshots =find_snapshots
        until snapshots.length > 0
          retries += 1
          raise "FATAL: Retry count exceeded 5" unless retries < 5
          sleep 100
          snapshots =find_snapshots
        end
        # get file count
        count = snapshots.length
        sleep 200
        raise "FATAL: Failed Continuous Backup Enable Test" unless find_snapshots.length > count
        # Disable cron job
       run_script("do_disable_continuous_backups_volume", s_one)
        sleep 200
        count =find_snapshots.length
        sleep 200
        raise "FATAL: Failed Continuous Backup Disable Test" unless find_snapshots.length == count
      end
  
      def release_container
        set_variation_container
        ary = []
        raise "FATAL: could not cleanup because @container was '#{@container}'" unless @container
        s3 = Fog::Storage.new(:provider => 'AWS')
        ary << s3.directories.all.select {|d| d.key =~ /^#{@container}/}
        if Fog.credentials[:rackspace_username] and Fog.credentials[:rackspace_api_key]
          rax = Fog::Storage.new(:provider => 'Rackspace')
          ary << rax.directories.all.select {|d| d.key =~ /^#{@container}/}
        else
          puts "No Rackspace Credentials!"
        end
        ary.each do |con|
          con.each do |dir|
            dir.files.each do |file|
              file.destroy
            end
            dir.destroy
          end
        end
      end
  
    end
  end
end 
