# -*- coding: utf-8 -*-

require 'fileutils'
require 'yaml'

require 'tengine/support/core_ext/hash/deep_dup'
require 'tengine/support/null_logger'

require "scm_workspace/version"

class ScmWorkspace

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

  def puts_info(msg)
    logger.info(msg)
    $stdout.puts(msg) if verbose
  end

  def configure(url)
    if configured?
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
      puts_info "git clone #{url} #{repo_dir}"
      require 'git'
      @git = Git.clone(url, repo_dir)
    when :svn then
      Dir.chdir(@root) do
        cmd = "git svn clone #{url} #{repo_dir} #{opt}"
        cmd << " > /dev/null 2>&1" unless verbose
        logger.info("*" * 100)
        logger.info("SCM configure")
        puts_info "cd #{@root} && " + cmd
        system(cmd)
      end
      @git = nil
    else
      raise "Unknown SCM type: #{url}"
    end
  end

  def clear
    return unless Dir.exist?(repo_dir)
    Dir.chdir(repo_dir) do
      (Dir.glob("*") + Dir.glob(".*")).each do |d|
        next if d =~ /\A\.+\Z/
        FileUtils.remove_entry_secure(d)
      end
    end
  end

  def checkout(branch_name)
    logger.info("-" * 100)
    puts_info "git checkout #{branch_name}"
    git.checkout(branch_name)
    case scm_type
    when :git then
      puts_info "git reset --hard origin/#{branch_name}"
      git.reset_hard("origin/#{branch_name}")
    end
  end

  def reset_hard(tag)
    case scm_type
    when :git then
      logger.info("-" * 100)
      puts_info("git reset --hard #{tag}")
      git.reset_hard(tag)
    when :svn then raise "Illegal operation for svn"
    end
  end
  alias_method :move, :reset_hard

  def fetch
    case scm_type
    when :git then
      logger.info("-" * 100)
      puts_info("git fetch origin")
      git.fetch("origin")
    when :svn then in_repo_dir{ system("git svn fetch") }
    end
  end

  def status
    case scm_type
    when :git then
      logger.info("-" * 100)
      puts_info("git status")
      status_text = in_repo_dir{ `git status` }
      value = status_text.scan(/Your branch is behind 'origin\/#{current_branch_name}' by (\d+\s+commits)/)
      if value && !value.empty?
        "There is/are #{value.flatten.join}"
      else
        "everything is up-to-dated."
      end
    when :svn then
      current_sha = git.log.first.sha
      status_text = in_repo_dir{
        cmd = "git log --branches --oneline #{current_sha}.."
        puts_info cmd
        `#{cmd}`
      }
      lines = status_text.split(/\n/)
      if lines.empty?
        "everything is up-to-dated."
      else
        latest_sha = lines.first
        "There is/are #{lines.length} commits." + in_repo_dir{
          " current revision: " << `git svn find-rev #{current_sha}`.strip <<
          " latest revision: " << `git svn find-rev #{latest_sha}`.strip
        }
      end
    end
  end

  def current_commit_key
    return nil unless configured?
    result = git.log.first.sha
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

  def branch_names
    return nil unless configured?
    case scm_type
    when :git then
      result = git.branches.remote.map(&:full).map{|path| path.sub(/\Aremotes\/origin\//, '')}
      result.delete_if{|name| name =~ /\AHEAD ->/}
      result
    when :svn then
      git.branches.remote.map(&:full).map{|path| path.sub(/\Aremotes\//, '')}
    end
  end

  def tag_names
    return nil unless configured?
    git.tags.map(&:name).uniq
  end

  def url
    return nil unless configured?
    case scm_type
    when :git then git.remote("origin").url
    when :svn then svn_info[:repository_root]
    end
  end

  def current_branch_name
    return nil unless configured?
    case scm_type
    when :git then git_current_branch_name
    when :svn then svn_current_branch_name
    end
  end

  def git_current_branch_name(dir = repo_dir)
    return nil unless Dir.exist?(dir)
    Dir.chdir(dir) do
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
    return nil unless configured?
    log = git.log.first
    git.tags.select{|b| b.log.first.sha == log.sha}.map(&:name)
  end


  def repo_dir
    @root
  end

  def configured?
    Dir.exist?(File.join(repo_dir, ".git"))
  end

  def cleared?
    !configured?
  end

  def git
    require 'git'
    @git ||= Git.open(repo_dir, log: logger)
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
    return nil unless configured?
    !git.remotes.empty? rescue false
  end

  def svn_repo?
    return nil unless configured?
    Dir.exist?(File.join(repo_dir, '.git', 'svn'))
  end

  def scm_type
    return nil unless configured?
    return :git if git_repo?
    return :svn if svn_repo?
    nil
  end

  def svn_info
    in_repo_dir do
      txt = `git svn info`
      return txt.scan(/^(.+?): (.*)$/).each_with_object({}){|(k,v), d| d[k.downcase.gsub(/\s/, '_').to_sym] = v }
    end
  end

  def in_repo_dir
    Dir.chdir(repo_dir) do
      return yield
    end
  end


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
