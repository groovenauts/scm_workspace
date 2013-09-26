# -*- coding: utf-8 -*-

require 'fileutils'
require 'yaml'

require 'tengine/support/core_ext/hash/deep_dup'
require 'tengine/support/null_logger'

require "scm_workspace/version"

class ScmWorkspace

  attr_reader :root
  attr_writer :logger
  def initialize(config, options = {})
    @root = config[:workspace]
    @logger = options[:logger]
  end

  def logger
    @logger ||= Tengine::Support::NullLogger.new
  end

  def puts_info(msg)
    logger.info(msg)
    $stdout.puts(msg)
  end

  def configure(url)
    raise "#{repo_dir} is not empty. You must clear it" if configured?
    raise "#{root} does not exist" unless Dir.exist?(root)
    url, opt = url.split(/\s+/, 2)
    scm_type = self.class.guess_scm_type(url)
    options = opt ? parse_options(opt, scm_type) : {}
    options['url'] = url
    save_options(options)
    case scm_type
    when :git then
      logger.info("*" * 100)
      logger.info("SCM configure")
      puts_info "git clone #{url} #{repo_dir}"
      require 'git'
      @git = Git.clone(url, repo_dir)
    when :svn then
      Dir.chdir(@root) do
        cmd = "git svn clone #{url} #{repo_dir} #{opt} > /dev/null 2>&1"
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
    FileUtils.remove_entry_secure(repo_dir) if Dir.exist?(repo_dir)
    FileUtils.rm(options_path) if File.exist?(options_path)
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
    when :git then
      logger.info("-" * 100)
      r = git.log.first.name
      logger.info("current_branch_name: #{r.inspect}")
      r
    when :svn then
      info = svn_info
      r = info[:url].sub(info[:repository_root], '')
      r.sub!(/\A\//, '')
      if branch_prefix = load_options['branches']
        r.sub!(branch_prefix + "/", '')
      end
      r
    end
  end

  def current_tag_names
    return nil unless configured?
    log = git.log.first
    git.tags.select{|b| b.log.first.sha == log.sha}.map(&:name)
  end


  def repo_dir
    File.join(@root, "workspace")
  end

  def options_path
    File.join(@root, "options.yml")
  end

  def configured?
    Dir.exist?(repo_dir)
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

  def parse_options(opt, scm_type)
    # "-T trunk --branches branches --tags tags -hoge --on" という文字列を
    #   [["-T", "trunk"], ["--branches", "branches"], ["--tags", "tags"], ["-hoge", nil], ["--on", nil]]
    # という風に分割します
    key_values = opt.scan(/(-[^\s]+)(?:\=|\s+)?([^-][^\s]+)?/)
    result = key_values.each_with_object({}){|(k,v), d| d[k.sub(/\A-{1,2}/, '').gsub(/-/, '_')] = v }
    CONFIGURE_OPTIONS[scm_type].each do |short_key, long_key|
      if v = result.delete(short_key)
        result[long_key] = v
      end
    end
    result
  end

  def save_options(hash)
    open(options_path, "w") do |f|
      YAML.dump(hash, f)
    end
  end

  def load_options
    return {} unless File.readable?(options_path)
    YAML.load_file(options_path)
  end
  alias_method :options, :load_options

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
