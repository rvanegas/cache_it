module ActiveRecord
  module CacheIt
    def self.included(base)
      base.send :include, InstanceMethods
      base.extend(ClassMethods)
    end

    module InstanceMethods
      def cache_it_write
        expires_in = self.class.cache_it_config.expires_in
        cache_it_keys.each {|key| Rails.cache.write(key, {:attributes => attributes}, :expires_in => expires_in)}
        cache_it_stale_keys.each {|key| Rails.cache.delete(key)}
        cache_it_init_counters
      end

      def cache_it_increment(counter, amount = 1)
        counter = counter.to_s
        unless self.class.cache_it_config.counters.include? counter
          raise ArgumentError, "#{counter} is not a counter"
        end
        primary_key = self.class.primary_key
        if key = self.class.cache_it_key({primary_key => self[primary_key]}, :counter => counter)
          self[counter] = Rails.cache.increment(key, amount, :raw => true)
        end
      end

      def cache_it_delete
        cache_it_keys.each do |key|
          Rails.cache.delete(key)
        end
      end

      def cache_it_init_counters
        primary_key = self.class.primary_key
        self.class.cache_it_config.counters.map do |counter|
          counter_key = self.class.cache_it_key({primary_key => self[primary_key]}, :counter => counter)
          self[counter] = Rails.cache.fetch(counter_key, :raw => true) { self[counter] }
        end
      end

      private
      def attributes_before_changes
        result = Hash.new
        attributes.each do |k,v| 
          result[k] = changes.include?(k) ? changes[k].first : v
        end
        return result
      end

      def cache_it_keys(attrs = attributes)
        self.class.cache_it_config.indexes.map do |index|
          self.class.cache_it_key attrs.select {|attr| index.include? attr}
        end
      end

      def cache_it_stale_keys
        cache_it_keys(attributes_before_changes) - cache_it_keys(attributes)
      end
    end

    module ClassMethods
      def self.extended(base)
        attr_reader :cache_it_config
        base.after_save :cache_it_write
        base.after_destroy :cache_it_delete
      end

      def cache_it_key(attrs, options = {})
        attrs = attrs.stringify_keys
        index = attrs.keys.sort
        raise ArgumentError, "index not available" unless cache_it_config.indexes.include? index
        if options[:counter]
          raise ArgumentError, "not a counter" unless cache_it_config.counters.include? options[:counter]
        end
        key = ["CacheIt.v1", self.name]
        key.push options[:counter] if options[:counter]
        key.push index.map{|name| [name, attrs[name]]}.to_json
        return key.join(":")
      end

      def cache_it_find(attrs, options = {})
        unless obj = cache_it_read(attrs, options)
          obj = where(attrs).first
          obj.cache_it_write if obj
        end
        return obj
      end

      def cache_it_read(attrs, options = {})
        key = cache_it_key(attrs)
        obj = nil
        if val = Rails.cache.read(key)
          attributes = val[:attributes]
          obj = new
          attributes.keys.each {|name| obj[name] = attributes[name]}
          obj.cache_it_init_counters unless options[:skip_counters]
          obj.instance_variable_set("@new_record", false) if obj.id
        end
        return obj
      end

      private
      def cache_it_init(config)
        @cache_it_config = config
      end
    end

    class Config
      attr_reader :indexes

      def initialize(model)
        @model = model
        @indexes ||= [[@model.primary_key]]
        @counters ||= []
      end

      def index(*index)
        return nil unless index.present?
        index = index.map {|n|n.to_s}.sort
        unless index.all? {|n| @model.column_names.include? n}
          raise ArgumentError, "index must be list of column names" 
        end
        @indexes.push index unless @indexes.include? index
        validate
        return nil
      end

      def counters(*counters)
        return @counters unless counters.present?
        counters = counters.map {|n|n.to_s}
        unless counters.all? {|n| @model.columns_hash[n].try(:type) == :integer}
          raise ArgumentError, "counters must be column names for integer attributes" 
        end
        counters.each do |name| 
          @counters.push name unless @counters.include? name
        end
        validate
        return nil
      end

      def expires_in(expires_in = nil, &block)
        unless expires_in or block_given?
          @expires_in.respond_to?(:call) ? @expires_in.call : @expires_in
        else
          raise ArgumentError, "use block or args" if expires_in and block_given?
          @expires_in = expires_in || block
          return nil
        end
      end

      private
      def validate
        if @indexes.flatten.any? {|name| @counters.include? name}
          raise "cannot use column for both index and counter" 
        end
      end
    end
  end

  class Base
    def self.cache_it(*index)
      include CacheIt
      config = CacheIt::Config.new(self)
      raise ArgumentError, "use block or args" if index.present? and block_given?
      config.index *index if index.present?
      yield config if block_given?
      cache_it_init config
    end
  end
end
