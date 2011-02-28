module ActiveRecord
  module ModelCache
    def self.included(base)
      base.extend(ClassMethods)
    end
    def model_cache_keys
      self.class.indeces.map do |index|
        pairs = index.map do |name| 
          { name => self[name] }
        end
        self.class.model_cache_key pairs.inject :merge
      end
    end
    def write_to_cache
      model_cache_keys.each do |key|
        Rails.cache.write(key, {"id" => id, "attributes" => attributes})
      end
    end
    def delete_from_cache
      model_cache_keys.each do |key|
        Rails.cache.delete(key)
      end
    end
    module ClassMethods
      mattr_accessor :indeces
      def model_cache_key(attrs)
        attrs = attrs.stringify_keys
        index = attrs.keys.sort
        raise ArgumentError, "index not available" unless self.indeces.include? index
        key = index.map{|name| [name, attrs[name]]}
        key << self.name
        key << "ModelCache.v1"
        return key.to_json
      end
      def find_from_model_cache(attrs)
        key = model_cache_key(attrs)
        if val = Rails.cache.read(key)
          obj = new(val["attributes"])
          obj.id = val["id"]
          obj.instance_variable_set("@new_record", false)
        else
          obj = where(attrs).first
          obj.write_to_cache if obj
        end
        return obj
      end
      def add_to_indeces(*index)
        self.indeces ||= [["id"]]
        if index.present?
          index = index.map{|n|n.to_s}.sort
          unless index.all?{|n|self.column_names.include? n}
            raise ArgumentError, "index must be array of column names" 
          end
          self.indeces.push index unless self.indeces.include? index
        end
        self.after_save :write_to_cache
        self.after_destroy :delete_from_cache
        return nil
      end
    end
  end
  class Base
    def self.model_cache(*index)
      include ModelCache
      add_to_indeces(*index)
    end
  end
end
