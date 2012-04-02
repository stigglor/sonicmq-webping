#!/usr/bin/env ruby

require 'logger'
require 'rubygems'
require 'redis'
require 'json'
require 'xmlsimple'
require 'file-tail'
require 'yaml'
require 'digest'

class Hash
  # pass single or array of keys, which will be removed, returning the remaining hash
  def remove!(*keys)
    keys.each{|key| self.delete(key) }
    self
  end

  # non-destructive version
  def remove(*keys)
    self.dup.remove!(*keys)
  end
  
  #take keys of hash and transform those to a symbols
  def self.transform_keys_to_symbols(value)
    return value if not value.is_a?(Hash)
    hash = value.inject({}){|memo,(k,v)| memo[k.to_sym] = Hash.transform_keys_to_symbols(v); memo}
    return hash
  end
end

class Array
   def to_h
     Hash[*each_with_index.to_a.flatten]
   end
 end

class RedisStore
  def initialize(type) 
    @redis = Redis.new
    @type = type
  end
  
  def generateKey(data)
    return Digest::SHA1.hexdigest(data)
  end
   
  # Method to find alert ID
  def find_id?(alert)
    @redis.hgetall(@type).map do |k,v|
      # Parse each line returned within each field
      stored_alert = JSON.parse(v)
      # Convert stored_alert Hash keys to symbols, and return as array. This is due to the way JSON parses ruby hashes
      stored_alert_hash_converted = Hash.transform_keys_to_symbols(stored_alert)
      # Compare array of keys
      next unless (stored_alert_hash_converted.keys-alert.keys).empty? # If false, move onto next iteration
      # Now we can return an array of values (with :timestamp removed) and do a comparison
      next unless (stored_alert_hash_converted.remove(:timestamp, :connectid).values-alert.remove(:timestamp, :connectid).values).empty? # If false, move onto next interation
      # Now we can return k
      return k      
    end
    nil
  end
          
  # Write / Read / Delete entry from redis store based on id
  def write(id, alert)
    @redis.hset(@type, id, alert.to_json)
  end
  
  def delete(id)
    @redis.hdel(@type, id)
  end
  
  def read(id)
    unless @redis.hget(@type, id).nil?
      JSON.parse(@redis.hget(@type, id))
    else
      return nil
    end
  end

  def return_all
    @redis.hgetall(@type)
  end
  
  def update(id, timestamp)
    entry = JSON.parse(@redis.hget(@type, id))
    # Fix hash keys to symbols
    entry_hash_fixed = Hash.transform_keys_to_symbols(entry)
    # Update the stored alert timestamp
    alert_timestamp_updated = entry_hash_fixed.update({ :timestamp => timestamp.to_i })
    # Delete old ID (timestamp)
    delete(id)
    # Generate new ID as we have a new timestamp
    newid = generateKey(timestamp.to_s + alert_timestamp_updated.values.join)
    # Re-add alert with updated timestamp and ID (timestamp)
    return write(newid, alert_timestamp_updated), newid 
  end
end
  
class Alerting  
  def initialize(configfile)
    @store_crit = RedisStore.new('critical')
    @store_info = RedisStore.new('info')
    load_config(configfile)
    @log = Logger.new(@logfile)
    @log.level = @loglevel.to_i
    info_cleaner
    tail(@eventmonitorlog)
  end
  
  private
  
  # Method to cleanup old info alerts
  def info_cleaner
    Thread.new {
      while true
        cleaned = 0
        @store_info.return_all.each do |k,v|
          x = JSON.parse(v)
          alert_time = x['Timestamp'].to_i
          unless alert_time > Time.now.to_i-86400 # Is alert older than 24 hours?
            @store_info.delete(k)
            cleaned = cleaned + 1
          end
        end
        @log.info("Removed #{cleaned} old info alerts")
        sleep 3600 # Sleep for an hour until we loop
      end
    }
  end
   
  # Tail the EventMonitor log file for events
  def tail(logfilepath)
    raise RuntimeError, "Error, I cant seem to locate the EventMonitor logfile?" unless File.exists?(logfilepath)
    File.open(logfilepath) do |log|
      log.extend(File::Tail)
      log.interval = 2
      log.backward(0)
      log.tail do |line|
        alert = XmlSimple.xml_in(line)
        pattern_matcher(alert)
      end
    end
  end
  
  # Load defaults from config
  def load_config(configfile)
    config = YAML.load_file(configfile)
    config.each { |key, value|
      instance_variable_set("@#{key}", value) 
    }
  end
  
  # Identify alert type
  def pattern_matcher(alert)
    alert_hash_fixed = Hash.transform_keys_to_symbols(alert)
    alert_res = find_resources(alert_hash_fixed)
    info_alerts = %w( application.connection.ReplicationChannelSwitch 
                      application.connection.Drop 
                      application.connection.Redirect 
                      application.connection.Disconnect 
                      application.connection.Reject
                      application.flowcontrol.PubPause
                      application.flowcontrol.PubResume
                      application.flowcontrol.SendPause
                      application.flowcontrol.SendResume
                      application.message.Undelivered
                      system.alert.system.memory.CurrentUsage )
    info_recovery_alerts = %w( application.connection.Connect 
                               application.connection.ReplicationActivate )
    critical_alerts = %w( system.state.Offline
                          system.state.Unreachable
                          system.state.Failover
                          application.connection.ReplicationDisconnect
                          application.state.DmqCapacity
                          system.state.Shutdown
                          system.state.Unload
                          system.log.Threshold
                          system.log.Failure )
    critical_recovery_alerts = %w( system.state.Online
                                   application.connection.ReplicationConnect
                                   system.state.Load
                                   system.state.Startup )
    begin
      if critical_alerts.include?(alert_res[:type]) 
        @log.debug("alert: '#{alert_res[:type]}' is critcal, calling check_status")
        check_status(alert_res, :type => "critical")
      elsif info_alerts.include?(alert_res[:type])
        @log.debug("alert: '#{alert_res[:type]}' is info, calling check_status")
        check_status(alert_res, :type => "info")
      elsif critical_recovery_alerts.include?(alert_res[:type])
        @log.debug("alert: '#{alert_res[:type]}' is critcal_recovery, calling check_status")
        opposite_alerts = alert_opposites(alert_res[:type])
        check_status(alert_res, :opposites => "#{opposite_alerts}", :type => "critical_recovery")
      elsif info_recovery_alerts.include?(alert_res[:type])
        @log.debug("alert: '#{alert_res[:type]}' is info_recovery, calling check_status")
        opposite_alerts = alert_opposites(alert_res[:type])
        check_status(alert_res, :opposites => "#{opposite_alerts}", :type => "info_recovery")  
      else
        @log.debug("#{alert_res[:type]}: has been ignored by the pattern_matcher")
      end
    rescue => e
      @log.debug("Oops, something seems to have gone wrong while calling check_status") 
      @log.debug("Exception: #{e.message}")
      @log.debug("Stack: #{e.backtrace}")
    end 
  end
   
  # Workout the recovery alert from the failure alert
  def alert_opposites(type)
    begin
      if type.to_s == "system.state.Online"
        %w( system.state.Offline
            system.state.Failover
            system.state.Unreachable )
      elsif type.to_s == "system.state.Startup"
        %w( system.state.Shutdown )
      elsif type.to_s == "system.state.Load"
        %w( system.state.Unload )
      elsif type.to_s == "application.connection.ReplicationConnect"
        %w( application.connection.ReplicationDisconnect )
      elsif type.to_s == "application.connection.Connect"
        %w( application.connection.Drop 
            application.connection.Redirect 
            application.connection.Disconnect 
            application.connection.Reject )
      else type.to_s == "application.connection.ReplicationActivate"
        %w( application.connection.ReplicationChannelSwitch )
      end
    rescue => e
      @log.debug("Oops, no opposite alert was found for the recovery alert: #{type}") 
      @log.debug("Exception: #{e.message}")
      @log.debug("Stack: #{e.backtrace}")
    end
  end
  
  # Set alert resources
  def find_resources(alert)
    found_res = {}  
    found_res[:type] = alert[:Type].to_s unless alert[:Type].nil?
    found_res[:timestamp] = alert[:TimeStamp].to_s.split("").first(10).join.to_i unless alert[:TimeStamp].nil?
    found_res[:source] = alert[:Source].to_s unless alert[:Source].nil?
    found_res[:broker] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "Broker" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "Broker" }.nil?
    found_res[:container] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "Container" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "Container" }.nil?
    found_res[:user] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "User" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "User" }.nil?
    found_res[:client] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "ClientIPAddress" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "ClientIPAddress" }.nil? 
    found_res[:connectid] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "ConnectID" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "ConnectID" }.nil?
    found_res[:routing] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "Routing" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "Routing" }.nil?
    found_res[:connection_name] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "ConnectionName" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "ConnectionName" }.nil?
    found_res[:backup_addr] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "BackupAddr" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "BackupAddr" }.nil?
    found_res[:primary_addr] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "PrimaryAddr" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "PrimaryAddr" }.nil?
    found_res[:backup_port] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "BackupPort" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "BackupPort" }.nil?
    found_res[:primary_port] = alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "PrimaryPort" }['content'].to_s unless alert[:Attributes][0]['Attribute'].find { |i| i['id'] == "PrimaryPort" }.nil?
    found_res
  end
   
  # Find out if we already know about this alert, if not store it, if so, update the timestamp. If its a recovery, figure out the opposite and delete 
  def check_status(alert, args)
    if args[:type] == "critical"
      # Try to find the alert ID in the store, else set it as :timestamp for a new alert, allowing us to order results later on via Sinatra
      id = @store_crit.find_id?(alert) 
      @log.info("alert: '#{alert[:type]}', lets see if the store already knows about this?")
      unless id.nil?
        @log.info("found alert: '#{alert[:type]}' in store with ID: #{id}, updating timestamp to: #{alert[:timestamp]}")
        response, newid = @store_crit.update(id, alert[:timestamp])
        response ? @log.debug("Store update success, new ID: #{newid}") : @log.debug("Store update failed for new ID: #{newid}")
      else
        id = @store_crit.generateKey(alert[:timestamp].to_s + alert.values.join)
        @log.info("New alert: '#{alert[:type]}', lets store it...")
        @store_crit.write(id, alert) ? @log.debug("Store success for ID: #{id}") : @log.debug("Store failed for ID: #{id}") 
      end
    elsif args[:type] == "info"
      # Try to find the alert ID in the store, else set it as :timestamp for a new alert, allowing us to order results later on via Sinatra
      id = @store_info.find_id?(alert)
      @log.info("alert: '#{alert[:type]}', lets see if the store already knows about this?")
      unless id.nil?
        @log.info("found alert: '#{alert[:type]}' in store with ID: #{id}, updating timestamp to: #{alert[:timestamp]}")
        response, newid = @store_info.update(id, alert[:timestamp])
        response ? @log.debug("Store update success, new ID: #{newid}") : @log.debug("Store update failed for new ID: #{newid}")
      else
        id = @store_info.generateKey(alert[:timestamp].to_s + alert.values.join)
        @log.info("New alert: '#{alert[:type]}', lets store it...")
        @store_info.write(id, alert) ? @log.debug("Store success for ID: #{id}") : @log.debug("Store failed for ID: #{id}")
      end 
    elsif args[:type] == "critical_recovery"
      @log.debug("Looping though my opposite's to search the store?")
      begin
        args[:opposites].each do |opposite|           
          # Set the alert[:type] to the opposite
          new_alert = alert.update({:type => opposite})
          # See if theres an entry in the store?
          id = @store_crit.find_id?(new_alert)
          unless id.nil?
            @log.info("deleting alert ID: #{id}, Type: #{new_alert[:type]}")
            @store_crit.delete(id) ? @log.debug("Delete success for ID: #{id}") : @log.debug("Delete failed for ID: #{id}")
          else
            @log.debug("find_id? returned nil, moving onto next opposite iteration")
          end
        end
      rescue => e
        @log.debug("something went wrong during critical_recovery event, @store_crit.read(id) method returned nil during all interations, possibly cant match the opposite alert?")
        @log.debug("Exception: #{e.message}")
        @log.debug("Stack: #{e.backtrace}")
      end
    elsif args[:type] == "info_recovery"
      @log.debug("Looping though my opposite's to search the store?")
      begin
        args[:opposites].each do |opposite|           
          # Set the alert[:type] to the opposite
          new_alert = alert.update({:type => opposite})
          # See if theres an entry in the store?
          id = @store_info.find_id?(new_alert)
          unless id.nil?
            @log.info("deleting alert ID: #{id}, Type: #{new_alert[:type]}")
            @store_info.delete(id) ? @log.debug("Delete success for ID: #{id}") : @log.debug("Delete failed for ID: #{id}")
          else
            @log.debug("find_id? returned nil, moving onto next opposite iteration")
          end
        end
      rescue => e
        @log.debug("something went wrong during info_recovery event, @store_info.read(id) method returned nil during all interations, possibly cant match the opposite alert?")
        @log.debug("Exception: #{e.message}")
        @log.debug("Stack: #{e.backtrace}")
      end
    end  
  end
end

# Lets make some action happen
configfile = File.expand_path(File.dirname(__FILE__) + "/config.yaml")                           
raise RuntimeError, "Error, cant locate #{configfile}?" if !File.exists?(configfile)

Alerting.new(configfile)    