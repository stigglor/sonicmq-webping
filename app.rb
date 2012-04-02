#!/usr/bin/env ruby

require 'redis'
require 'json'
require 'haml'
require 'sass'
require 'compass'

set :env, :production
set :root, File.dirname(__FILE__)
set :views, "views"
set :public_folder, "static"
set :app_file, __FILE__
set :haml, { :format => :html5 }

helpers do
  def overall_status
    unless @redis.hgetall('critical').size > 0
      "OK"
    else
      "FAIL"
    end
  end
  def cycle
    @_cycle ||= reset_cycle
    @_cycle = [@_cycle.pop] + @_cycle
    @_cycle.first
  end
  def reset_cycle
    @_cycle = %w(even odd)
  end
  def return_entries(type)
    unless @redis.hgetall(type).size == 0
      @redis.hgetall(type).map do |alerts|
        JSON.parse(alerts[1])
      end
    else
      return nil
    end
  end
end

before do
  @redis = Redis.new
  @store_crit = return_entries('critical').sort_by { |k| k['timestamp'] }.reverse
  @store_info = return_entries('info').sort_by { |k| k['timestamp'] }.reverse
end

get '/stylesheets/:name.css' do
  content_type 'text/css', :charset => 'utf-8'
  sass(:"#{params[:name]}", Compass.sass_engine_options)
end
    
get '/summary' do 
  overall_status
end
  
get '/detailed' do
  haml :index
end
