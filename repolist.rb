#!/usr/bin/ruby

require 'sinatra'
require 'haml'
require 'kconv'
require 'tmpdir'
require 'fileutils'
require 'date'

# setting here
set :root, '/var/svn-repositories'
set :svn_binary_dir, '/usr/bin'
set :date_format, '%Y-%m-%d'
set(:uri_root) {|req| "https://#{req.host}/svn-repos-root/" }

class Repos
  attr_reader :name

  def self.create(dir, desc)
    r = new(dir)
    r.enable_log
    r.save(desc)
    r.get_log
  end

  def initialize(dir)
    raise ArgumentError, dir if dir =~ /\s/

    @dir = dir
    @name = File.basename(dir)
  end

  def path
    @dir
  end

  def enable_log
    @log ||= []
  end

  def get_log
    @log.join("\n")
  end

  def date
    @date ||= begin
      date = svnlook('date')
      date && DateTime.parse(date)
    end
  end

  def revision
    @revision ||= svnlook('youngest')
  end

  def readme
    @readme ||= svnlook('cat', 'README.txt')
  end

  def trunk_path
    @trunk ||= begin
      if exist?('/trunk/')
        "#{name}/trunk/"
      else
        "#{name}/"
      end
    end
  end

  def save(desc)
    raise "repos #{name} exists" if File.exist?(@dir)

    Dir.mktmpdir('repolist') do |dir|
      repos = File.join(dir, 'repos')
      workdir = File.join(dir, 'working-copy')

      svnadmin "create #{repos}"
      svn "checkout file://#{repos} #{workdir}"

      Dir.chdir(workdir) do
        %w/trunk tags branches/.each do |path|
          Dir.mkdir path
        end
        
        open('README.txt', 'w') do |f|
          f << desc.toutf8
        end

        svn "add trunk tags branches README.txt"
        svn "commit . -m 'initial commit'"
      end

      log "mv #{repos} #{@dir}"
      FileUtils.mv repos, @dir
      
      log "append to authz"
      File.open('/var/www/svn/.authz', 'a') do |f|
        f.puts
        f.puts "[#{name}:/]"
        f.puts "#{ENV['REMOTE_USER']} = rw"
      end
    end
  end

  private
  def exist?(path)
    not svnlook('history', "--limit 1 #{path}").nil?
  end

  def svn(arg)
    ok, result = command "#{settings.svn_binary_dir}/svn #{arg}"
    raise result unless ok
    result
  end

  def svnadmin(arg)
    ok, result = command "#{settings.svn_binary_dir}/svnadmin #{arg}"
    raise result unless ok
    result
  end

  def svnlook(cmd, arg=nil)
    ok, result = command "#{settings.svn_binary_dir}/svnlook #{cmd} #{@dir} #{arg}"
    ok ? result : nil
  end

  def command(cmd)
    log "-- #{cmd}"
    
    result = `LANG=C #{cmd} 2>&1`
    ok = $?.success?
    result = result.toutf8.strip

    log "== $?: #{$?}"
    log result
    
    return ok, result
  end

  def log(msg)
    @log << msg if defined?(@log)
  end
end

helpers do
  def view(name, locals={})
    haml(name, {}, locals)
  end

  def each_repos(&blk)
    folders = Dir.glob(File.join(settings.root, '*'))
    folders = folders.select {|d| File.directory?(d) && !d.include?('.') }
    repos = folders.map {|dir| Repos.new dir }
    repos.reject! {|r| !r.date }
    repos.sort! {|a,b| b.date <=> a.date }
    repos.each(&blk)
  end
end

get '/?' do
  view :index
end

post '/create/?' do
  name = request['name'] or break 'no name'
  desc = request['desc'] or break 'no desc'
  
  name.strip!
  desc.strip!

  break 'invalid name' unless name =~ /\A[a-z\d-]+\z/
  
  log = Repos.create(File.join(settings.root, name), desc)

  view :create, { :name => name, :log => log }
end

enable :inline_templates
set :haml, { :format => :html4, :ugly => true }
set :sass, { :style => :compact }

if $0 == __FILE__
  set :env, :cgi
  disable :run

  Rack::Handler::CGI.run Sinatra::Application
end

__END__
@@layout
%html
  %head
    %title repolist
    %meta(http-equiv="Content-type" content="text/html; charset=UTF-8")
    %style
      :sass
        body
          font-family: Arial
          background-color: #dffefa
        h1
          font-weight: normal
        table
          background-color: white
          border: 1px solid black
          border-collapse: collapse
          border-radius: 10px
          -webkit-border-radius: 10px
          -moz-border-radius: 10px
          th
            background-color: #deeffa
          th:hover
            background-color: #ffa
          th, td
            border: 1px solid black
            padding: 0.5em
          th.repos
            padding: 0
            margin: 0
            a
              display: block
              padding: 0.5em
              margin: 0
  %body
    = yield

@@index
%h1 List of repositories
%form#create-form(action="#{request.path}/create" method="post")
  %table
    %tr
      %th Name
      %th Date
      %th Description
    %tr#create
      %th.repos
        %input.name(type="text" name="name" size=20)
      %td
        %input(type="submit" value="Create")
      %td
        %textarea.desc(name="desc" rows=3 cols=40 wrap='soft')

    - each_repos do |repos|
      %tr
        %th.repos
          %a(href="#{settings.uri_root(request)}/#{repos.trunk_path}")= repos.name
        %td
          = "#{repos.date.nil? ? 'none' : repos.date.strftime(settings.date_format)} (r#{repos.revision})"
        %td= repos.readme ? repos.readme.gsub("\n", '<br/>') : '(No /README.txt)'

@@create
%h1
  %a(href="#{request.path}")= "repos #{name} created"
%pre= log