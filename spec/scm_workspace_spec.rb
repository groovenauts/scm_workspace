# -*- coding: utf-8 -*-
require 'spec_helper'

require 'tmpdir'
require 'fileutils'

# ApiServerモードでもScmWorkspaceクラスを使用するので、参照だけはできることを確認する。
describe ScmWorkspace do

  before(:all) do
    @tmp_workspace = Dir.mktmpdir
    @scm_workspace = ScmWorkspace.new(workspace: @tmp_workspace)
  end
  after(:all){ FileUtils.remove_entry_secure(@tmp_workspace) }

  context "not depend on git" do
    subject{ @scm_workspace }
    its(:repo_dir){ should_not == nil }
    it{ subject.configured? }
    it{ subject.cleared? }
  end

  context "git", git: true do
    before(:all){ @url = "git://github.com/akm/git_sandbox.git" }

    context "before configuring" do
      before do
        FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
      end
      subject{ @scm_workspace }

      its(:configured?){ should == false}
      its(:scm_type){ should == nil}
      its(:url){ should == nil}

      its(:scm_type){ should == nil}
      its(:git_repo?){ should == nil }
      its(:svn_repo?){ should == nil }

      its(:branch_names){ should == nil }
      its(:tag_names){ should == nil }

      its(:current_branch_name){ should == nil }
      its(:current_tag_names){ should == nil }

      its(:current_commit_key){ should == nil }
    end

    context "after configuring" do
      before(:all) do
        FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
        @scm_workspace.configure(@url)
      end
      subject{ @scm_workspace }

      its(:configured?){ should == true}
      its(:cleared?){ should == false }
      its(:url){ should == @url }

      its(:scm_type){ should == :git}
      its(:git_repo?){ should == true }
      its(:svn_repo?){ should == false }

      its(:branch_names){ should =~ %w[master develop 0.1 feature/function_d feature/function_e] }
      its(:tag_names){ should =~ %w[v0.0.1 v0.0.2 v0.1.0] }

      its(:current_branch_name){ should == "develop" }
      its(:current_tag_names){ should =~ %w[v0.0.2] }

      its(:current_commit_key){ should == "a0eaf8cca31080ca26edbae0daddaa9931edd6d6" }

      it :fetch do
        @scm_workspace.fetch
      end

      context "duplicated configuration" do
        it do
          expect{
            @scm_workspace.configure(@url)
          }.to raise_error(/not empty/i)
        end
      end
    end

    describe :checkout do
      context "another branch" do
        before(:all) do
          FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
          @scm_workspace.configure(@url)
          @scm_workspace.checkout("0.1")
        end
        subject{ @scm_workspace }
        its(:current_branch_name){ should == "0.1" }
        its(:current_tag_names){ should =~ %w[v0.1.0] }
      end

      context "branch is updated" do
        before(:all) do
          FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
          @scm_workspace.configure(@url)
          Dir.chdir(@scm_workspace.repo_dir) do
            # バージョンを巻き戻す
            system("git reset --hard a68a53610407e6ba30939326af743d3b734bb53d")
          end
        end
        it "checkout again" do
          @scm_workspace.status.should =~ /7 commits/
          @scm_workspace.checkout("develop")
          @scm_workspace.status.should =~ /up-to-dated/
        end
      end
    end

    describe :move do # reset --hard
      %w[v0.0.1 v0.0.2 v0.1.0].each do |tag|
        context "#{tag} in develop" do
          before(:all) do
            FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
            @scm_workspace.configure(@url)
            @scm_workspace.checkout("develop")
            @scm_workspace.move(tag)
          end
          subject{ @scm_workspace }
          its(:current_branch_name){ should == "develop" }
          its(:current_tag_names){ should =~ [tag] }
        end
      end
      context "reset to fix wrong reset" do
        before(:all) do
          FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
          @scm_workspace.configure(@url)
          @scm_workspace.checkout("develop")
          @scm_workspace.move("v0.1.0")
        end
        subject{ @scm_workspace }
        it do
          subject.current_branch_name.should == "develop"
          subject.current_tag_names.should =~ ["v0.1.0"]
          subject.checkout("develop")
          subject.current_branch_name.should == "develop"
          subject.current_tag_names.should =~ ["v0.0.2"]
        end
      end
    end

    describe :clear do
      before(:all) do
        FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
        @scm_workspace.configure(@url)
      end

      it do
        @scm_workspace.cleared?.should == false
        @scm_workspace.clear
        @scm_workspace.cleared?.should == true
        Dir.exist?(@scm_workspace.repo_dir).should == false
      end
    end

  end

  context "svn", svn: true do
    before(:all) do
      @base_url = "http://rubeus.googlecode.com/svn"
      @cloning_url = "#{@base_url} -T trunk --branches branches --tags tags"
    end

    context "after configuring" do
      before(:all) do
        FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
        @scm_workspace.configure(@cloning_url)
      end
      subject{ @scm_workspace }

      its(:configured?){ should == true}
      its(:cleared?){ should == false }
      its(:url){ should == @base_url }

      its(:scm_type){ should == :svn}
      its(:git_repo?){ should == false }
      its(:svn_repo?){ should == true }

      its(:branch_names){ should =~ %w[jdbc_migration rakeable rmaven tags/0.0.8 tags/REL-0.0.2 tags/REL-0.0.3 trunk] }
      its(:tag_names){ should == [] }

      its(:current_branch_name){ should == "trunk" }
      its(:current_tag_names){ should == []  }

      # git svn だと SHAはcloneするたびに変わるので末尾のSVNのリビジョン番号をチェックします
      its(:current_commit_key){ should =~ /\A[0-9a-f]{40}:247\Z/ }

      it :fetch do
        @scm_workspace.fetch
      end
    end

    context "duplicated configuration" do
      before(:all) do
        FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
        @scm_workspace.configure(@cloning_url)
      end
      subject{ @scm_workspace }

      it do
        expect{
          @scm_workspace.configure(@cloning_url)
        }.to raise_error(/not empty/i)
      end
    end

    describe :checkout do
      %w[rmaven tags/0.0.8].each do |branch_name|

        context branch_name do
          before(:all) do
            FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
            @scm_workspace.configure(@cloning_url)
            @scm_workspace.checkout(branch_name)
          end
          subject{ @scm_workspace }
          its(:current_branch_name){ should == branch_name }
          its(:current_tag_names){ should == [] }
        end

      end

      context "branch is updated" do
        before(:all) do
          FileUtils.remove_entry_secure(@scm_workspace.repo_dir) if Dir.exist?(@scm_workspace.repo_dir)
          @scm_workspace.configure(@cloning_url)
          @scm_workspace.checkout("trunk")
          Dir.chdir(@scm_workspace.repo_dir) do
            # バージョンを巻き戻す
            system("git reset --hard HEAD~3")
          end
        end

        it "checkout again" do
          @scm_workspace.current_commit_key.should =~ /\A[0-9a-f]{40}:244\Z/
          @scm_workspace.status.should =~ /3 commits.*current revision: 244.*latest revision: 247/
          @scm_workspace.checkout("trunk")
          @scm_workspace.current_commit_key.should =~ /\A[0-9a-f]{40}:247\Z/
          @scm_workspace.status.should =~ /up-to-dated/
        end

      end
    end
  end

end
