# -*- coding: utf-8 -*-

require 'fileutils'
require 'yaml'

require 'tengine/support/core_ext/hash/deep_dup'
require 'tengine/support/null_logger'

require "scm_workspace/version"
require "scm_workspace/core_ext/fileutils"

class ScmWorkspace

  class Error < StandardError
  end

  attr_reader :root
  attr_writer :logger
  attr_accessor :svn_branch_prefix
  attr_accessor :verbose
  def initialize(config, options = {})
    @root = config[:workspace]
    @logger = options[:logger]
    @verbose = options[:verbose] || (ENV["VERBOSE"] =~ /true|yes|on/)
    @svn_branch_prefix = options[:svn_branch_prefix] || ENV["SVN_BRANCH_PREFIX"] || "branches"
  end

  def logger
    @logger ||= Tengine::Support::NullLogger.new
  end

  def fileutils
    @fileutils ||= FileUtils.with_logger(logger)
  end

  def system!(cmd)
    logger.info("executing: #{cmd}")
    buf = []
    IO.popen("#{cmd} 2>&1") do |io|
      while line = io.gets
        # puts line
        buf << line
      end
    end

    if $?.exitstatus == 0
      msg = "\e[33mSUCCESS: %s\e[0m" % cmd
      r = buf.join
      msg << "\n" << r.strip if verbose
      logger.info(msg)
      return r
    else
      msg = "\e[31mFAILURE: %s\n%s\e[0m" % [cmd, buf.join.strip]
      logger.error(msg)
      raise Error, msg
    end
  end

  def system_at_root!(cmd)
    fileutils.chdir(root){ system!(cmd) }
  end

  def configure(url)
    unless empty?
      msg = "#{repo_dir} is not empty. You must clear it"
      msg << "\nls -la #{repo_dir}" << `ls -la #{repo_dir}` if verbose
      raise msg
    end
    url, opt = url.split(/\s+/, 2)
    scm_type = self.class.guess_scm_type(url)
    case scm_type
    when :git then
      logger.info("*" * 100)
      logger.info("SCM configure")
      system!("git clone #{url} #{repo_dir} #{opt}")
    when :svn then
      fileutils.chdir(@root) do
        cmd = "git svn clone #{url} #{repo_dir} #{opt}"
        cmd << " > /dev/null 2>&1" unless verbose
        logger.info("*" * 100)
        logger.info("SCM configure")
        system(cmd)
      end
    else
      raise "Unknown SCM type: #{url}"
    end
  end

  def clear
    return unless Dir.exist?(root)
    fileutils.chdir(root) do
      (Dir.glob("*") + Dir.glob(".*")).each do |d|
        next if d =~ /\A\.+\Z/
        logger.info("remove_entry_secure #{d.inspect}")
        fileutils.remove_entry_secure(d)
      end
    end
  end

  def empty?
    return true unless Dir.exist?(root)
    fileutils.chdir(root) do
      return (Dir.glob("*") + Dir.glob(".*")).reject{|d| d =~ /\A\.+\Z/}.empty?
    end
  end

  def checkout(branch_name)
    logger.info("-" * 100)
    system_at_root!("git checkout #{branch_name}")
    case scm_type
    when :git then system_at_root!("git reset --hard origin/#{branch_name}")
    end
  end

  def reset_hard(tag)
    logger.info("-" * 100)
    case scm_type
    when :git then system_at_root!("git reset --hard #{tag}")
    when :svn then raise "Illegal operation for svn"
    end
  end
  alias_method :move, :reset_hard

  def fetch
    logger.info("-" * 100)
    case scm_type
    when :git then system_at_root!("git fetch origin")
    when :svn then system_at_root!("git svn fetch")
    end
  end

  def status
    logger.info("-" * 100)
    case scm_type
    when :git then
      status_text = system_at_root!("git status") # in_repo_dir{ `git status` }
      value = status_text.scan(/Your branch is behind 'origin\/#{current_branch_name}' by (\d+\s+commits)/)
      if value && !value.empty?
        "There is/are #{value.flatten.join}"
      else
        "everything is up-to-dated."
      end
    when :svn then
      status_text = system_at_root!("git log --branches --oneline #{current_sha}..")
      lines = status_text.split(/\n/)
      if lines.empty?
        "everything is up-to-dated."
      else
        latest_sha = lines.first
        "There is/are #{lines.length} commits." <<
          " current revision: " << system_at_root!("git svn find-rev #{current_sha}").strip <<
          " latest revision: "  << system_at_root!("git svn find-rev #{latest_sha}").strip
      end
    end
  end

  def current_sha
    return nil unless accessible?
    system_at_root!("git log -1").scan(/^commit ([0-9a-f]+)$/).flatten.first
  end

  def current_commit_key
    return nil unless accessible?
    result = current_sha
    case scm_type
    when :svn then
      rev = nil
      cnt = 0
      while rev.nil?
        rev = in_repo_dir{ `git svn find-rev #{result}`.strip }
        cnt += 1
        raise "failed to get svn revision for #{result}" if cnt > 10
      end
      result << ':' << rev
    end
    result
  end

  def commit_info
    {
      "scm_type" => scm_type.to_s,
      "url" => url,
      "branch" => current_branch_name,
      "commit_key" => current_commit_key
    }
  end

  def branch_names
    return nil unless accessible?
    case scm_type
    when :git then
      result = system_at_root!("git branch -r").lines.map{|path| path.sub(/\A\s*origin\//, '').strip }
      result.delete_if{|name| name =~ /\AHEAD ->/}
      result
    when :svn then
      system_at_root!("git branch -r").lines.map{|path| path.strip }
    end
  end

  def remotes
    system_at_root!("git remote -v show").lines.each_with_object({}) do |line, d|
      name, url, other = line.strip.split(/[\t\s]+/, 3)
      d[name] = url
    end
  end

  def tag_names
    return nil unless accessible?
    system_at_root!("git tag").lines.map{|path| path.strip.strip }
  end

  def url
    return nil unless accessible?
    case scm_type
    when :git then remotes["origin"]
    when :svn then svn_info[:repository_root]
    end
  end

  def current_branch_name
    return nil unless accessible?
    case scm_type
    when :git then git_current_branch_name
    when :svn then svn_current_branch_name
    end
  end

  def git_current_branch_name(dir = repo_dir)
    return nil unless Dir.exist?(dir)
    fileutils.chdir(dir) do
      # http://qiita.com/sugyan/items/83e060e895fa8ef2038c
      result = `git symbolic-ref --short HEAD`.strip
      return result unless result.nil? || result.empty?
      result = `git status`.scan(/On branch\s*(.+)\s*$/).flatten.first
      return result unless result.nil? || result.empty?
      work = `git log --decorate -1`.scan(/^commit\s[0-9a-f]+\s\((.+)\)/).
        flatten.first.split(/,/).map(&:strip).reject{|s| s =~ /HEAD\Z/}
      r = work.select{|s| s =~ /origin\//}.first
      r ||= work.first
      result = r.sub(/\Aorigin\//, '')
      return result
    end
  rescue => e
    # puts "[#{e.class}] #{e.message}"
    # puts "Dir.pwd: #{Dir.pwd}"
    # puts "git status\n" << `git status`
    raise e
  end

  def svn_current_branch_name
    info = svn_info
    r = info[:url].sub(info[:repository_root], '')
    r.sub!(/\A\//, '')
    r.sub!(svn_branch_prefix + "/", '')
    r
  end

  def current_tag_names
    return nil unless accessible?
    system_at_root!("git describe --tags #{current_sha}").lines.map(&:strip) rescue []
  end


  def repo_dir
    @root
  end

  # submoduleでない場合 true
  # submoduleの場合     true
  # gitの対象外の場合   false
  def accessible?
    File.exist?(File.join(repo_dir, ".git"))
  end

  # submoduleでない場合 true
  # submoduleの場合     false
  # gitの対象外の場合   false
  def configured?
    Dir.exist?(File.join(repo_dir, ".git"))
  end


  def cleared?
    # !configured?
    empty?
  end

  def contains?(obj)
    !!system_at_root!("git show #{obj} --oneline --quiet") rescue false
  end

  CONFIGURE_OPTIONS = {
    svn: {
      "A" => "authors_file",
      "b" => "branches",
      "m!" => "minimize_rul",
      "q+" => "quiet",
      "r" => "revision",
      "s" => "stdlayout",
      "t" => "tags",
      "T" => "trunk",
    },

    git: {
      'n' => 'no_checkout',
      'l' => 'local',
      's' => 'shared',
      'o' => 'origin',
      'b' => 'branch',
      'u' => 'upload_pack',
      'c' => 'config',
    }
  }

  def git_repo?
    return nil unless accessible?
    !remotes.empty? rescue false
  end

  def svn_repo?
    return nil unless accessible?
    Dir.exist?(File.join(repo_dir, '.git', 'svn'))
  end

  def scm_type
    return nil unless accessible?
    return :git if git_repo?
    return :svn if svn_repo?
    nil
  end

  def svn_info
    txt = system_at_root!("git svn info")
    return txt.scan(/^(.+?): (.*)$/).each_with_object({}){|(k,v), d| d[k.downcase.gsub(/\s/, '_').to_sym] = v }
  end

  def in_root
    fileutils.chdir(repo_dir) do
      return yield
    end
  end
  alias_method :in_repo_dir, :in_root

  class << self
    def guess_scm_type(url)
      case url
      when /\Agit:\/\//, /\Agit\@/, /\.git\Z/ then :git
      when /svn/ then :svn
      else nil
      end
    end
  end

end
