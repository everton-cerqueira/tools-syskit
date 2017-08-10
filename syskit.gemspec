# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'syskit/version'

Gem::Specification.new do |s|
  s.name = "syskit"
  s.version = Syskit::VERSION
  s.authors = ["Sylvain Joyeux"]
  s.email = "sylvain.joyeux@m4x.org"
  s.summary = "Component network management extension for Roby"
  s.description = <<-EOD
The Roby plan manager is currently developped from within the Robot Construction
Kit (http://rock-robotics.org). Have a look there. Additionally, the [Roby User
Guide](http://rock-robotics.org/api/tools/roby) is a good place to start with
Roby.

Syskit is a Roby extension that handles component-based networks
  EOD
  s.homepage = "http://rock-robotics.org"
  s.licenses = ["BSD"]

  s.require_paths = ["lib"]
  s.extra_rdoc_files = ["README.md"]
  s.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
end
