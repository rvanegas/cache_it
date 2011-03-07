module ActiveRecord
  module ModelCache
    def self.included(base)
      base.extend(ClassMethods)
    end

    def mcache_keys
      self.class.mcache_config.indexes.map do |index|
        self.class.mcache_key attributes.select {|attr| index.include? attr}
      end
    end

    def mcache_write
      keys = mcache_keys
      primary = keys.shift
      expires_in = self.class.mcache_config.expires_in
      keys.each {|key| Rails.cache.write(key, {:primary => primary}, :expires_in => expires_in)}
      Rails.cache.write(primary, {:attributes => attributes}, :expires_in => expires_in)
    end

    def mcache_increment(counter, amount = 1)
      counter = counter.to_s
      unless self.class.mcache_config.counters.include? counter
        raise ArgumentError, "#{counter} is not a counter"
      end
      primary_key = self.class.primary_key
      if key = self.class.mcache_key({primary_key => self[primary_key]}, :counter => counter)
        Rails.cache.write(key, self[counter], :raw => true) unless Rails.cache.read(key)
        self[counter] = Rails.cache.increment(key, amount, :raw => true)
      end
    end

    def mcache_delete
      mcache_keys.each do |key|
        Rails.cache.delete(key)
      end
    end

    module ClassMethods
      def self.extended(base)
        attr_reader :mcache_config
        base.after_save :mcache_write
        base.after_destroy :mcache_delete
      end

      def mcache_key(attrs, options = {})
        attrs = attrs.stringify_keys
        index = attrs.keys.sort
        raise ArgumentError, "index not available" unless mcache_config.indexes.include? index
        key = index.map{|name| [name, attrs[name]]}
        key.push options[:counter] if options[:counter]
        key.push self.name
        key.push Rails.env
        key.push "ModelCache.v1"
        return key.to_json
      end

      def mcache_find(attrs)
        unless obj = mcache_read(attrs)
          obj = where(attrs).first
          obj.mcache_write if obj
        end
        return obj
      end

      def mcache_read(attrs)
        key = mcache_key(attrs)
        obj = nil
        if val = Rails.cache.read(key)
          val = Rails.cache.read(val[:primary]) if val[:primary]
          attributes = val[:attributes]
          obj = new
          attributes.keys.each {|key| obj[key] = attributes[key]}
          obj.instance_variable_set("@new_record", false) if obj.id
        end
        return obj
      end

      private
      def mcache_init(config)
        @mcache_config = config
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
        index = index.map{|n|n.to_s}.sort
        unless index.all?{|n| @model.column_names.include? n}
          raise ArgumentError, "index must be list of column names" 
        end
        @indexes.push index unless @indexes.include? index
        validate
        return nil
      end

      def counters(*counters)
        return @counters unless counters.present?
        counters = counters.map{|n|n.to_s}
        unless counters.all?{|n| @model.column_names.include? n}
          raise ArgumentError, "counters must be column names for integer attributes" 
        end
        counters.each do |name| 
          @counters.push name unless @counters.include? name
        end
        validate
        return nil
      end

      def expires_in(expires_in = nil)
        return @expires_in unless expires_in
        @expires_in = expires_in
        return nil
      end

      def validate
        if @indexes.flatten.any? {|name| @counters.include? name}
          raise "cannot use column for both index and counter" 
        end
      end
    end
  end

  class Base
    def self.model_cache(options = {})
      include ModelCache
      config = ModelCache::Config.new(self)
      yield config if block_given?
      config.index *options[:index] if options[:index]
      config.counters *options[:counters] if options[:counters]
      mcache_init config
    end
  end
end
