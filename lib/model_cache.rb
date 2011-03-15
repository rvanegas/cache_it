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
      expires_in = self.class.mcache_config.expires_in
      mcache_keys.each {|key| Rails.cache.write(key, {:attributes => attributes}, :expires_in => expires_in)}
      mcache_init_counters
    end

    def mcache_init_counters
      primary_key = self.class.primary_key
      self.class.mcache_config.counters.map do |counter|
        counter_key = self.class.mcache_key({primary_key => self[primary_key]}, :counter => counter)
        self[counter] = Rails.cache.fetch(counter_key, :raw => true) { self[counter] }
      end
    end

    def mcache_increment(counter, amount = 1)
      counter = counter.to_s
      unless self.class.mcache_config.counters.include? counter
        raise ArgumentError, "#{counter} is not a counter"
      end
      primary_key = self.class.primary_key
      if key = self.class.mcache_key({primary_key => self[primary_key]}, :counter => counter)
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
        if options[:counter]
          raise ArgumentError, "not a counter" unless mcache_config.counters.include? options[:counter]
        end
        key = ["ModelCache.v1", self.name]
        key.push options[:counter] if options[:counter]
        key.push index.map{|name| [name, attrs[name]]}.to_json
        return key.join(":")
      end

      def mcache_find(attrs, options = {})
        unless obj = mcache_read(attrs, options)
          obj = where(attrs).first
          obj.mcache_write if obj
        end
        return obj
      end

      def mcache_read(attrs, options = {})
        key = mcache_key(attrs)
        obj = nil
        if val = Rails.cache.read(key)
          attributes = val[:attributes]
          obj = new
          attributes.keys.each {|name| obj[name] = attributes[name]}
          obj.mcache_init_counters unless options[:skip_counters]
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
    def self.model_cache(*index)
      include ModelCache
      config = ModelCache::Config.new(self)
      raise ArgumentError, "use block or args" if index.present? and block_given?
      config.index *index if index.present?
      yield config if block_given?
      mcache_init config
    end
  end
end
