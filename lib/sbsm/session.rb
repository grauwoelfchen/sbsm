#!/usr/bin/env ruby
# encoding: utf-8
#
# State Based Session Management
#	Copyright (C) 2004 Hannes Wyss
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#	ywesee - intellectual capital connected, Winterthurerstrasse 52, CH-8006 Zürich, Switzerland
#	hwyss@ywesee.com
#
# SBSM::Session -- sbsm -- 27.09.2012 -- yasaka@ywesee.com
# SBSM::Session -- sbsm -- 17.01.2012 -- mhatakeyama@ywesee.com
# SBSM::Session -- sbsm -- 22.10.2002 -- hwyss@ywesee.com

require 'cgi'

require 'sbsm/cgi'
require 'sbsm/drb'
require 'sbsm/state'
require 'sbsm/lookandfeelfactory'
require 'delegate'

module SBSM
  class	Session < SimpleDelegator
		attr_reader :user, :active_thread, :app, :key, :cookie_input,
			:unsafe_input, :valid_input, :request_path, :cgi
		include DRbUndumped
		PERSISTENT_COOKIE_NAME = "sbsm-persistent-cookie"
		DEFAULT_FLAVOR = 'sbsm'
		DEFAULT_LANGUAGE = 'en'
		DEFAULT_STATE = State
		DEFAULT_ZONE = nil
		DRB_LOAD_LIMIT = 255 * 102400
    EXPIRES = 60 * 60
		LF_FACTORY = nil
		LOOKANDFEEL = Lookandfeel
		CAP_MAX_THRESHOLD = 8
		MAX_STATES = 4
		SERVER_NAME = nil
    def Session.reset_stats
      @@stats = {}
    end
    reset_stats
    @@stats_ptrn = /./
    def Session.show_stats ptrn=@@stats_ptrn
      if ptrn.is_a?(String)
        ptrn = /#{ptrn}/i
      end
      puts sprintf("%8s %8s %8s %6s %10s Request-Path",
                   "Min", "Max", "Avg", "Num", "Total")
      grand_total = requests = all_max = all_min = 0
      @@stats.collect do |path, times|
        total = times.inject do |a, b| a + b end
        grand_total += total
        size = times.size
        requests += size
        max = times.max
        all_max = max > all_max ? max : all_max
        min = times.min
        all_min = min < all_min ? min : all_min
        [min, max, total / size, size, total, path]
      end.sort.each do |data|
        line = sprintf("%8.2f %8.2f %8.2f %6i %10.2f %s", *data)
        if ptrn.match(line)
          puts line
        end
      end
      puts sprintf("%8s %8s %8s %6s %10s Request-Path",
                   "Min", "Max", "Avg", "Num", "Total")
      puts sprintf("%8.2f %8.2f %8.2f %6i %10.2f",
                   all_min, all_max,
                   requests > 0 ? grand_total / requests : 0,
                   requests, grand_total)
      ''
    end
    def initialize(key, app, validator=nil)
			touch()
      reset_input()
			reset_cookie()
      @app = app
      @key = key
			@validator = validator
			@attended_states = {}
			@persistent_user_input = {}
			logout()
			@unknown_user_class = @user.class
			@variables = {}
      @mutex = Mutex.new
      @cgi = CGI.initialize_without_offline_prompt('html4')
			super(app)
    end
    def age(now=Time.now)
      now - @mtime
    end
		def cap_max_states
			if(@attended_states.size > self::class::CAP_MAX_THRESHOLD)
				#puts "too many states in session! Keeping only #{self::class::MAX_STATES}"
				#$stdout.flush
				sorted = @attended_states.values.sort
				sorted[0...(-self::class::MAX_STATES)].each { |state|
					state.__checkout
					@attended_states.delete(state.object_id)
				}
        @attended_states.size
			end
		end
		def __checkout
			@attended_states.each_value { |state| state.__checkout }
			@attended_states.clear
			flavor = @persistent_user_input[:flavor]
			lang = @persistent_user_input[:language]
			@persistent_user_input.clear
			@persistent_user_input.store(:flavor, flavor)
			@persistent_user_input.store(:language, lang)
			@valid_input.clear
			@unsafe_input.clear
			@active_thread = nil
			true
		end
    @@msie_ptrn = /MSIE/
    @@win_ptrn = /Win/i
		def client_activex?
      (ua = user_agent) && @@msie_ptrn.match(ua) && @@win_ptrn.match(ua)
		end
    @@nt5_ptrn = /Windows\s*NT\s*(\d+\.\d+)/i
		def client_nt5?
      (ua = user_agent) \
        && (match = @@nt5_ptrn.match(user_agent)) \
        && (match[1].to_f >= 5)
		end
		def cookie_set_or_get(key)
			if(value = @valid_input[key])
				set_cookie_input(key, value)
			else
				@cookie_input[key]
			end
		end
		def get_cookie_input(key)
			@cookie_input[key]
		end
		def cookie_name
			self::class::PERSISTENT_COOKIE_NAME
		end
		def default_language
			self::class::DEFAULT_LANGUAGE
		end
		def direct_event
			@state.direct_event
		end
    def drb_process(request)
      start = Time.now
      html = @mutex.synchronize do
        process(request)
        to_html
      end
      (@@stats[@request_path] ||= []).push(Time.now - start)
      html
    end
		def error(key)
			@state.error(key) if @state.respond_to?(:error)
		end
		def errors
			@state.errors.values if @state.respond_to?(:errors)
		end
		def error?
			@state.error? if @state.respond_to?(:error?)
		end
		def event
			@valid_input[:event]
		end
    def event_bound_user_input(key)
      @event_user_input ||= {}
      evt = state.direct_event
      @event_user_input[evt] ||= {}
      if(val = user_input(key))
        @event_user_input[evt][key] = val
      else
        @event_user_input[evt][key]
      end
    end
		def expired?(now=Time.now)
      age(now) > EXPIRES
		end
		def force_login(user)
			@user = user
		end
		def import_cookies(request)
			reset_cookie()
      return if request.cookies.is_a?(DRb::DRbUnknown)
      if(cuki = request.cookies[self::class::PERSISTENT_COOKIE_NAME])
        cuki.each { |cuki_str|
          CGI.parse(CGI.unescape(cuki_str)).each { |key, val|
            key = key.intern
            valid = @validator.validate(key, val.compact.last)
            @cookie_input.store(key, valid)
          }
        }
      end
		end
    @@hash_ptrn = /([^\[]+)((\[[^\]]+\])+)/
    @@index_ptrn = /[^\[\]]+/
    def import_user_input(request)
			# attempting to read the cgi-params more than once results in a
			# DRbConnectionRefused Exception. Therefore, do it only once...
			return if(@user_input_imported)
      request.params.each { |key, value|
				#puts "importing #{key} -> #{value}"
				index = nil
				@unsafe_input.push([key.to_s.dup, value.to_s.dup])
				unless(key.nil? || key.empty?)
					if match = @@hash_ptrn.match(key)
						key = match[1]
						index = match[2]
						#puts key, index
					end
					key = key.intern
					if(key == :confirm_pass)
						pass = request.params["pass"]
						#puts "pass:#{pass} - confirm:#{value}"
						@valid_input[key] = @valid_input[:set_pass] \
							= @validator.set_pass(pass, value)
					else
						valid = @validator.validate(key, value)
						if(index)
              target = (@valid_input[key] ||= {})
              indices = []
              index.scan(@@index_ptrn) { |idx|
                indices.push idx
              }
              last = indices.pop
              indices.each { |idx|
                target = (target[idx] ||= {})
              }
              target.store(last, valid)
						else
							@valid_input[key] = valid
              "dummy" # Some statement is necessary here to avoid Date data loading error on Ruby 1.9.3
						end
					end
				end
				#puts "imported #{key} -> #{value} => #{@valid_input[key].inspect}"
      }
			@user_input_imported = true
			#puts @unsafe_input.inspect
			#puts @valid_input.inspect
			#$stdout.flush
    end
		def infos
			@state.infos if @state.respond_to?(:infos)
		end
		def info?
			@state.info? if @state.respond_to?(:info?)
		end
		def is_crawler?
			@is_crawler ||= if @request.respond_to?(:is_crawler?)
                        @request.is_crawler?
                      end
		end
		def language
			cookie_set_or_get(:language) || default_language
		end
		def logged_in?
			!@user.is_a?(@unknown_user_class)
		end
		def login
			if(user = @app.login(self))
				@user = user
			end
		end
		def logout
			__checkout
			@user = @app.unknown_user()
			@active_state = @state = self::class::DEFAULT_STATE.new(self, @user)
      @state.init
			@attended_states.store(@state.object_id, @state)
		end
		def lookandfeel
			if(@lookandfeel.nil? \
				|| (@lookandfeel.flavor != flavor) \
				|| (@lookandfeel.language != persistent_user_input(:language)))
				@lookandfeel = if self::class::LF_FACTORY
					self::class::LF_FACTORY.create(self)
				else
					self::class::LOOKANDFEEL.new(self)
				end
			end
			@lookandfeel
		end
		def flavor
			@flavor ||= begin
				user_input = persistent_user_input(:flavor)
				user_input ||= @valid_input[:default_flavor]
				lf_factory = self::class::LF_FACTORY
				if(lf_factory && lf_factory.include?(user_input))
					user_input
				else
					self::class::DEFAULT_FLAVOR
				end
			end
		end
		def http_headers
			@state.http_headers
    rescue DRb::DRbConnError
      raise
		rescue NameError, StandardError => err
      puts "error in SBSM::Session#http_headers: #@request_path"
      puts err.class, err.message
      puts err.backtrace[0,5]
			{'Content-Type' => 'text/plain'}
		end
		def http_protocol
			@http_protocol ||=	if(@request.respond_to?(:server_port) \
														&& @request.server_port == 443)
														'https'
													else
														'http'
													end
		end
		def input_keys
			@valid_input.keys
		end
		def navigation
			@user.navigation
		end
		def passthru(*args)
			@request.passthru(*args)
		end
		def persistent_user_input(key)
			if(value = user_input(key))
				@persistent_user_input.store(key, value)
			else
				@persistent_user_input[key]
			end
		end
		def process(request)
			begin
				@request = request
        @request_method = request.request_method
        @request_path = @request.unparsed_uri
				@validator.reset_errors() if @validator
				import_user_input(request)
				import_cookies(request)
				@state = active_state.trigger(event())
        #FIXME: is there a better way to distinguish returning states?
        #       ... we could simply refuse to init if event == :sort, but that
        #       would not solve the problem cleanly, I think.
        unless(@state.request_path)
          @state.request_path = @request_path
          @state.init
        end
				unless @state.volatile?
					@active_state = @state
					@attended_states.store(@state.object_id, @state)
				end
				@zone = @active_state.zone
				@active_state.touch
				cap_max_states
      rescue DRb::DRbConnError
        raise
			rescue StandardError => err
        #@state = @state.previous
				puts "error in SBSM::Session#process: #@request_path"
				puts err.class, err.message
				puts err.backtrace[0,5]
				$stdout.flush
			ensure
				@user_input_imported = false
			end
			''
		end
		def reset
=begin
			if(@active_thread \
				&& @active_thread.alive? \
				&& @active_thread != Thread.current)
				begin
					#@active_thread.exit
				rescue StandardError
				end
			end
			@active_thread = Thread.current
=end
      if @redirected
        @redirected = false
      else
        reset_input()
      end
		end
		def reset_cookie
			@cookie_input = {}
		end
    def reset_input
      @valid_input = {}
			@processing_errors = {}
			@http_protocol = nil
			@flavor = nil
			@unsafe_input = []
    end
		def remote_addr
			@remote_addr ||= if @request.respond_to?(:remote_addr)
				@request.remote_addr
			end
		end
		def remote_ip
			@remote_ip ||= if(@request.respond_to?(:remote_host))
				@request.remote_host
			end
		end
		def set_cookie_input(key, val)
			@cookie_input.store(key, val)
		end
		def server_name
			@server_name ||= if @request.respond_to?(:server_name)
				@request.server_name
			else
				self::class::SERVER_NAME
			end
		rescue DRb::DRbConnError
			@server_name = self::class::SERVER_NAME
		end
		def state(event=nil)
			@active_state
		end
    def touch
      @mtime = Time.now
      self
    end
		def to_html
			@state.to_html(cgi)
    rescue DRb::DRbConnError
      raise
		rescue StandardError => err
      puts "error in SBSM::Session#to_html: #@request_path"
      puts err.class, err.message
      puts err.backtrace#[0,5]
      $stdout.flush
			[ err.class, err.message ].join("\n")
		end
    def user_agent
      @user_agent ||= (@request.user_agent if @request.respond_to?(:user_agent))
    end
    @@input_ptrn = /([^\[]+)\[([^\]]+)\]/
    def user_input(*keys)
			if(keys.size == 1)
				index = nil
				key = keys.first.to_s
				if match = @@input_ptrn.match(key)
					key = match[1]
					index = match[2]
				end
				key_sym = key.to_sym
				valid = @valid_input[key_sym]
				if(index && valid.respond_to?(:[]))
					valid[index]
				else
					valid
				end
			else
				keys.inject({}) { |inj, key|
					inj.store(key, user_input(key))
					inj
				}
			end
    end
		def valid_values(key)
			vals = @validator.valid_values(key) unless @validator.nil?
			vals || []
		end
		def warnings
			@state.warnings if @state.respond_to?(:warnings)
		end
		def warning?
			@state.warning? if @state.respond_to?(:warning?)
		end
    # CGI::SessionHandler compatibility
    def restore
			#puts "restore was called"
			#@unix_socket = DRb.start_service('drbunix:', self)
      hash = {
				#:proxy   =>  DRbObject.new(self, @unix_socket.uri)
				:proxy	=>	self,
      }
			hash.extend(DRbUndumped) # added for Ruby1.8 compliance
      hash
    end
    def update
      # nothing
    end
    def close
			#@unix_socket.stop_service
      # nothing
    end
    def delete
      @app.delete_session @key
    end
		def zone
			@valid_input[:zone] || @state.zone || self::class::DEFAULT_ZONE
		end
		def zones
			@active_state.zones
		end
		def zone_navigation
			@state.zone_navigation
		end
		def ==(other)
			super
		end
		def <=>(other)
			self.weighted_mtime <=> other.weighted_mtime
		end
		def [](key)
			@variables[key]
		end
		def []=(key, val)
			@variables[key] = val
		end
		private
		def active_state
			if(state_id = @valid_input[:state_id])
				@attended_states[state_id]
			end || @active_state
		end
		protected
		attr_reader :mtime
		def weighted_mtime
			@mtime + @user.session_weight
		end
  end
end
