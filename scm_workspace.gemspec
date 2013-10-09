# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'scm_workspace/version'

Gem::Specification.new do |spec|
  spec.name          = "scm_workspace"
  spec.version       = ScmWorkspace::VERSION
  spec.authors       = ["akima"]
  spec.email         = ["akima@groovenauts.jp"]
  spec.description   = %q{support loading scm repogitory into local workspace}
  spec.summary       = %q{support loading scm repogitory into local workspace}
  spec.homepage      = ""
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  # spec.add_runtime_dependency "git"
  spec.add_runtime_dependency "tengine_support"

  spec.add_development_dependency "bundler", "~> 1.3"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"

  spec.add_development_dependency "pry"
  spec.add_development_dependency "fuubar"
end
