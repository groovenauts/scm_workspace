require 'spec_helper'

require 'scm_workspace/core_ext/fileutils'
require "stringio"
require "tmpdir"

describe FileUtils do

  let(:io){ StringIO.new }
  let(:logger){ Logger.new(io) }
  let(:fu){ FileUtils.with_logger(logger) }

  describe :chdir do
    it "default" do
      dir = File.expand_path("../..", __FILE__)
      fu.chdir(dir) do
        fu.pwd.should == dir
      end
      io.rewind
      lines = io.read.lines
      lines.length.should == 2
      lines[0].should =~ /\AI, \[.+\]\s+INFO -- : cd #{Regexp.escape(dir)}/
      lines[1].should =~ /\AI, \[.+\]\s+INFO -- : cd -/
    end

    it "debug" do
      debug_fu = FileUtils.with_logger(logger, :debug)
      dir = File.expand_path("../..", __FILE__)
      debug_fu.chdir(dir) do
        debug_fu.pwd.should == dir
      end
      io.rewind
      lines = io.read.lines
      lines.length.should == 2
      lines[0].should =~ /\AD, \[.+\]\s+DEBUG -- : cd #{Regexp.escape(dir)}/
      lines[1].should =~ /\AD, \[.+\]\s+DEBUG -- : cd -/
    end
  end

  describe :mkdir_p do
    it "default" do
      path = nil
      Dir.mktmpdir do |dir|
        path = File.join(dir, "foo/bar")
        fu.mkdir_p(path)
        Dir.exist?(path).should be_true
      end
      io.rewind
      lines = io.read.lines
      lines.length.should == 1
      lines[0].should =~ /\AI, \[.+\]\s+INFO -- : mkdir -p #{Regexp.escape(path)}/
    end
  end

  describe :touch do
    it "default" do
      path = nil
      Dir.mktmpdir do |dir|
        path = File.join(dir, "restart.txt")
        fu.touch(path)
        File.exist?(path).should be_true
        IO.read(path).should == ""
      end
      io.rewind
      lines = io.read.lines
      lines.length.should == 1
      lines[0].should =~ /\AI, \[.+\]\s+INFO -- : touch #{Regexp.escape(path)}/
    end
  end

end
