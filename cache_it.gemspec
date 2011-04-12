# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "cache_it/version"

Gem::Specification.new do |s|
  s.name        = "cache_it"
  s.version     = CacheIt::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Rodrigo Vanegas"]
  s.email       = ["rvanegas@gmail.com"]
  s.homepage    = ""
  s.summary     = %q{ActiveRecord caching}
  s.description = %q{Integrates ActiveRecord with cache stores provided by Rails.cache, incluing memcached}

  s.rubyforge_project = "cache_it"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end
