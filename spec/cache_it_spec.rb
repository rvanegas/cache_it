
require 'ruby-debug'
Debugger.start

require 'sqlite3'
require 'active_record'
require File.expand_path(File.dirname(__FILE__) + '/../lib/cache_it.rb')

class MockCache
  def initialize
    clear
  end
  
  def write(key, val, options = {})
    @hash[key] = val
  end

  def read(key)
    @hash[key]
  end

  def fetch(key, options = {})
    if @hash.has_key?(key)
      @hash[key]
    elsif block_given?
      @hash[key] = yield
    end
  end

  def increment(key, amount = 1, options = {})
    @hash[key] = @hash[key].to_s.to_i + amount
  end

  def delete(key)
    @hash.delete(key)
  end

  def clear
    @hash = Hash.new
  end
end

describe MockCache do
  it "writes and reads" do
    subject.read("foo").should== nil
    subject.write("foo", 1)
    subject.read("foo").should== 1
  end

  it "fetches" do
    subject.read("foo").should== nil
    subject.fetch("foo", 1){ 1 }.should== 1
    subject.read("foo").should== 1
    subject.fetch("foo", 1).should== 1
  end

  it "increments" do
    subject.read("foo").should== nil
    subject.increment("foo")
    subject.increment("foo", 2)
    subject.write("foo", 1)
    subject.increment("foo")
    subject.increment("foo", 2)
    subject.read("foo").should== 4
  end

  it "deletes" do
    subject.read("foo").should== nil
    subject.write("foo", 1)
    subject.read("foo").should== 1
    subject.delete("foo")
    subject.read("foo").should== nil
  end
end

ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => ":memory:")

silence_stream(STDOUT) do
  ActiveRecord::Schema.define(:version => 1) do
    create_table :users do |t|
      t.string :code
      t.string :name
      t.boolean :flag, :default => false
      t.integer :points, :default => 0
    end
  end
end

class Rails
  @@cache = MockCache.new
  def self.cache
    @@cache
  end
end

class User < ActiveRecord::Base
  cache_it do |c|
    c.index :code
    c.index :name
    c.counters :points
  end
end

describe CacheIt do
  context "User" do
    before do
      User.delete_all
      Rails.cache.clear
      @u = User.create(:code => "x", :name => "joe")
    end

    it "reads" do
      User.cache_it.read(:name => "joe").should== @u
    end

    it "writes" do
      @u.name = "jane"
      @u.cache_it.write
      User.cache_it.read(:name => "jane").should== @u
      User.find_by_sql("select * from users where id = #{@u.id}").first.name.should== "joe"
      @u.save!
      User.find_by_sql("select * from users where id = #{@u.id}").first.name.should== "jane"
    end

    it "increments" do
      @u.cache_it.increment(:points)
      @u.points.should== 1
      User.find_by_sql("select * from users where name = 'joe'").first.points.should== 0
      @u.save!
      User.find_by_sql("select * from users where name = 'joe'").first.points.should== 1
    end

    it "deletes stale keys" do
      @u.code = "y"
      @u.save!
      User.cache_it.read(:code => "x").should== nil
    end

    it "deletes stale keys on destroy" do
      @u.code = "y"
      @u.destroy
      User.cache_it.read(:code => "x").should== nil
    end

    it "syncs counters" do
      @u.cache_it.increment(:points)
      @u2 = User.cache_it.read(:name => "joe")
      @u2.points.should== 1
      @u2.cache_it.increment(:points)
      @u3 = User.cache_it.read({:name => "joe"}, :skip_counters => true)
      @u3.points.should== 0
      @u4 = User.cache_it.read(:name => "joe")
      @u4.points.should== 2
    end

    it "nil for read of unknown keys" do
      User.cache_it.read(:name => "dave").should== nil
    end

    it "flags set right" do
      @u2 = User.cache_it.read(:name => "joe")
      @u2.new_record?.should== false
      @u2.persisted?.should== true
    end

    it "doesn't accept unknown index" do
      expect { User.cache_it.read(:points => 10) }.to raise_error(/index not available/)
    end

    it "saves boolean correctly on repetition" do
      User.all[0].flag.should == false
      u = User.cache_it.find :name => "joe"
      u.flag = true
      u.save
      User.all[0].flag.should == true
      u = User.cache_it.find :name => "joe"
      u.flag = false
      u.save
      User.all[0].flag.should == false
      u = User.cache_it.find :name => "joe"
      u.flag = true
      u.save
      User.all[0].flag.should == true
      u = User.cache_it.find :name => "joe"
      u.flag = false
      u.save
      User.all[0].flag.should == false
    end
  end

  context "config" do
    before do
      @users_class = Class.new ActiveRecord::Base
      @users_class.set_table_name "users"
    end
    
    it "can't use same column for both index and counter" do
      expect do
        @users_class.cache_it do |c|
          c.index :name, :points
          c.counters :points
        end
      end.to raise_error(/cannot use column/)
    end

    it "can use arg" do
      expect do
        @users_class.cache_it :code
      end.to_not raise_error
    end

    it "can't use arg and block" do
      expect do
        @users_class.cache_it(:code) {|c| c.index :name}
      end.to raise_error(/block or args/)
    end

    it "accepts constant for expires" do
      expect do
        @users_class.cache_it {|c| c.expires_in 3}
      end.to_not raise_error
    end

    it "accepts proc for expires" do      
      expect do
        @users_class.cache_it {|c| c.expires_in { 3 }}
      end.to_not raise_error
    end

    it "counter must be integer column" do
      expect do
        @users_class.cache_it {|c| c.counters :name}
      end.to raise_error(/must be column names for integer/)
    end
    
    it "counter must be existing column" do
      expect do
        @users_class.cache_it {|c| c.counters :not_a_column}
      end.to raise_error(/must be column names for integer/)
    end

    it "each class gets its own config" do
      @users_class2 = Class.new ActiveRecord::Base
      @users_class2.set_table_name "users"
      @users_class2.cache_it.config.should_not== @users_class.cache_it.config
    end

    it "cannot config twice" do
      expect {@users_class.cache_it :name}.to_not raise_error
      expect {@users_class.cache_it :name}.to raise_error
    end
  end
end
