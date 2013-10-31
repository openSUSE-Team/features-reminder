#!/usr/bin/ruby

require 'active_record'
require 'optparse'
require 'date'
require 'ostruct'
require 'open3'

# Defaults for the options
options = OpenStruct.new
options.convert = false
options.reset = false
options.mail = false
options.base = "diff"
options.hack = false
options.db = "changes.sqlite"
options.ethreshold = 250
options.pthreshold = 150
options.default_points = 100
options.update_points = 50
options.feature_points = 100

# Parse the options
OptionParser.new do |opts|
  opts.banner = "Usage: #{ARGV[0]} [options]"

  opts.on("-b", "--base STR", "Base dir where to read changes from") do |v|
    options[:base] = v
  end
  opts.on("-d", "--db STR", "Path to the sqlite database") do |v|
    options[:db] = v
  end
  opts.on("-c", "--convert", "Convert diffs into database") do |v|
    options[:convert] = v
  end
  opts.on("-r", "--reset", "Reset weights") do |v|
    options[:reset] = v
  end
  opts.on("-m", "--mail", "Send mails") do |v|
    options[:mail] = v
  end
  opts.on("-u", "--ugly-hack", "Drop everything and ignore package weights (faster init)") do |v|
    options[:hack] = v
  end
  opts.on("-e", "--email-threshold NUM", Float, "Threshold to send mails") do |v|
    options[:ethreshold] = v
  end
  opts.on("-p", "--package-threshold NUM", Float, "Threshold to show package") do |v|
    options[:pthreshold] = v
  end
  opts.on_tail("-h", "--help", "--usage", "Shows this message") do |v|
    puts opts.help
    exit
  end
end.parse!

# Connect to the database
ActiveRecord::Base.establish_connection(
   :adapter => "sqlite3",
   :database => options.db
)

# Check and recreate database
ActiveRecord::Schema.define do
   # Package weights
   if ! ActiveRecord::Base.connection.table_exists? 'pkgs'
   create_table :pkgs do |table|
      table.column :name, :text
      table.column :points, :integer
   end
   end
   if ! ActiveRecord::Base.connection.index_exists?(:pkgs, :name)
      add_index(:pkgs, :name)
   end
   # Changes database
   if ! ActiveRecord::Base.connection.table_exists? 'changes'
   create_table :changes do |table|
      table.column :email, :text
      table.column :date, :datetime
      table.column :pkg, :text
      table.column :text, :text
      table.column :points, :integer
   end
   end
   if ! ActiveRecord::Base.connection.index_exists?(:changes, :points)
      add_index(:changes, :points)
   end
   if ! ActiveRecord::Base.connection.index_exists?(:changes, [:email, :date, :pkg])
      add_index(:changes, [:email, :date, :pkg])
   end
   if ! ActiveRecord::Base.connection.index_exists?(:changes, :email)
      add_index(:changes, :email)
   end
end

# Activerecord
class Change < ActiveRecord::Base
end
class Pkg < ActiveRecord::Base
end

# Splits the file into database
def process_file(file, hack)
   email = ""
   date  = ""
   text  = ""
   pkg   = file.gsub(/.*\/(.*).changes/,'\1')
   File.open(file).each do |line|
      line = line.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
      if line =~ /-------------------------------------------------------------------/
         text = text.strip
         if !text.empty?
            if hack || (Change.where(:email => email, :date => date, :pkg => pkg).count == 0)
               Change.create(:email => email, :date => date, :text => text.strip, :points => 0, :pkg => pkg)
            end
         end
         email = ""
         date  = ""
         text  = ""
      else if email.empty? && date.empty? && (m = line.match /^([A-Z][a-z][a-z].*2[0-2][0-9][0-9]) - (.*@.*)$/)
            email = m[2].sub('suse.cz','suse.com').sub('suse.de','suse.com')
            begin
              date  = DateTime.parse(m[1])
            rescue
              date  = DateTime.parse("Jan 1 00:00:00 UTC 1970")
            end
         else
            text += line
         end
      end
   end
end


# Import diffs into database to make the rest of operations easier
if options.convert
   puts "Importing changes from #{options.base}:"
   if options.hack
      Change.delete_all
   end
   Dir.entries(options.base).sort.select do |f|
      if !File.directory? f
         print " - importing changes from #{f}...\n"
         process_file options.base + "/" + f + "/" + f + ".changes", options.hack
      end
   end
end

# Reset points allocated
if options.reset
   puts "Reseting weights"
   Change.update_all("points=0")
end


# Assign some weights to anything that has zero points
points=options.default_points
last_pkg=""

puts "Updating weights of unevaluated changes"
if options.hack
   Change.where("text like '%update%'").update_all(:points => options.update_points * options.default_points)
   Change.where("text like '%Update%'").update_all(:points => options.update_points * options.default_points)
   Change.where("text like '%Version%'").update_all(:points => options.update_points * options.default_points)
   Change.where("text like '%version%'").update_all(:points => options.update_points * options.default_points)
   Change.where("text like '%feature%'").update_all(:points => options.feature_points * options.default_points)
   Change.where("text like '%Feature%'").update_all(:points => options.feature_points * options.default_points)
   Change.where("points=0").update_all(:points => options.default_points)
end
Change.where("points=0").order(:pkg).each do |change|
   if change.pkg != last_pkg
      # Try to find points for package
      pkg_data = Pkg.where(:name => change.pkg).first
      if pkg_data == nil
         points=options.default_points
      else
         points=pkg_data.points
      end
      last_pkg = change.pkg
      puts " - updating weights of package #{last_pkg}"
   end
   change.points = points
   if change.text =~ /.*[Uu]pdate.*/ || change.text =~ /.*[Vv]ersion.*/
      change.points=points * options.update_points
   end
   if change.text =~ /.*[Ff]eature.*/
      change.points=points * options.feature_points
   end
   change.save
end

# Summarize changes
puts ""
puts "End result is:"
puts ""
Change.group(:email).select("sum(points) as points_sum,email").order("points_sum DESC").each do |people|
   if people.points_sum > options.ethreshold * options.default_points
      text=""
      others=false
      i=0
      Change.where(:email => "#{people.email}").group(:pkg).select("sum(points) as points_sum,pkg").order("points_sum DESC").each do |package|
         i+=1
         if (package.points_sum > options.pthreshold * options.default_points) && (i<10)
            text+="   * #{package.pkg}\n"
         else
            others = true
         end
      end
      if !text.empty?
         if options.mail
            mail  = "From: Michal Hrusecky <mhrusecky@suse.cz>\n"
            mail += "Subject: Tell us about new features in openSUSE 13.1\n"
            mail += "\n"
            mail += "Hi,\n"
            mail += "\n"
            mail += "we have detected that you did quite some interesting changes to some of your\n"
            mail += "packages during development of new openSUSE 13.1.\n"
            mail += "\n"
            if i>2
               mail += "Namely we noticed:\n"
               mail += "\n"
               mail += text
               mail += "   ...\n" unless !others
               mail += "\n"
            end
            mail += "Do you think these changes are worth promoting? Marketing team is currently\n"
            mail += "looking for interesting features to promote, so if you know about some (doesn't\n"
            mail += "have to be necessarily yours), please put them to this wiki page:\n"
            mail += "\n"
            mail += "http://en.opensuse.org/openSUSE:Major_features\n"
            mail += "\n"
            mail += "If you are worried that you can't write pretty, don't be. Marketing team will\n"
            mail += "tidy up this wiki page, but they need help with getting content - interesting\n"
            mail += "new features they can write about.\n"
            mail += "\n"
            mail += "If you have already added a nice description to the wiki, you have our eternal\n"
            mail += "gratitude and this mail was not meant to tell you it was not good enough!\n"
            mail += "\n"
            stdin, stdout, stderr = Open3.popen3('/usr/sbin/sendmail', people.email)
            stdin.puts(mail)
            stdin.close
            puts "Sent mail to #{people.email}"
         else
            puts "We should send mail to #{people.email}, and ask about:"
            puts ""
            puts text
            puts "   ..." unless !others
            puts ""
         end
      end
   end
end

