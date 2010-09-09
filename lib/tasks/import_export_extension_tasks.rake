require 'pp'

namespace :db do
  desc "Import a database template from db/export.yml. Specify the TEMPLATE environment variable to load a different template. This is not intended for new installations, but restoration from previous exports."
  task :import do
    require 'highline/import'
    say "ERROR: Specify a template to load with the TEMPLATE environment variable." and exit unless (ENV['TEMPLATE'] and File.exists?(ENV['TEMPLATE']))
    Rake::Task["db:schema:load"].invoke
    # Use what Radiant::Setup for the heavy lifting
    require 'radiant/setup'
    require 'lib/radiant_setup_create_records_patch'
    setup = Radiant::Setup.new

    # Load the data from the export file
    data = YAML.load_file(ENV['TEMPLATE'] || "#{RAILS_ROOT}/db/export.yml")

#    # Load the users first so created_by fields can be updated
#    users_only = {'records' => {'Users' => data['records'].delete('Users')}}
#    passwords = []
#    users_only['records']['Users'].each do |id, attributes|
#      if attributes['password']
#        passwords << [attributes['id'], attributes['password'], attributes['salt']]
#        attributes['password'] = 'radiant'
#        attributes['password_confirmation'] = 'radiant'
#      end
#    end
#    setup.send :create_records, users_only
#
#    # Hack to get passwords transferred correctly.
#    passwords.each do |id, password, salt|
#      User.update_all({:password => password, :salt => salt}, ['id = ?', id])
#    end

    # Now load the created users into the hash and load the rest of the data
    data['records'].each do |klass, records|
      records.each do |key, attributes|
        if attributes.has_key? 'created_by'
          attributes['created_by'] = User.find(attributes['created_by']) rescue nil
        end
        if attributes.has_key? 'updated_by'
          attributes['updated_by'] = User.find(attributes['updated_by']) rescue nil
        end
      end
    end
    setup.send :create_records, data

    # if env set, adjust the auto increment counter, needed for DB2
    if ENV['FIXIDS']
      puts
      data['records'].each do |klass, records|
        tabname = klass.to_s.singularize.constantize.table_name

        if ActiveRecord::Base.connection and !ActiveRecord::Base.connection.schema.to_s.empty?
          tabname = ActiveRecord::Base.connection.schema.to_s + '.' + tabname
        end

        res = ActiveRecord::Base.connection.select_value("SELECT max(id)+1 from #{tabname};")

        if res
          puts "Adjusting auto increment value for the id column of #{tabname}..."
          ActiveRecord::Base.connection.execute("alter table #{tabname} alter column id restart with #{res};")
        end
      end
      puts 'Done.'
    end
  end

  desc "Export a database template to db/export_TIME.yml. Specify the TEMPLATE environment variable to use a different file."
  task :export do
    require "activerecord" if !defined?(ActiveRecord)
    require "#{RAILS_ROOT}/config/environment.rb"
    ActiveRecord::Base.establish_connection
    require "#{File.expand_path(File.dirname(__FILE__) + '/../')}/loader.rb"
    require "#{File.expand_path(File.dirname(__FILE__) + '/../')}/exporter.rb"
    template_name = ENV['TEMPLATE'] || "#{RAILS_ROOT}/db/export_#{Time.now.utc.strftime("%Y%m%d%H%M%S")}.yml"
    File.open(template_name, "w") { |f| f.write Exporter.export }
  end

  desc "Import data"
  task :import_vhost => :environment do
    require 'highline/import'
    say "ERROR: Specify a template to load with the TEMPLATE environment variable." and exit unless (ENV['TEMPLATE'] and File.exists?(ENV['TEMPLATE']))
    # Load the data from the export file
    data = YAML.load_file(ENV['TEMPLATE'] || "#{RAILS_ROOT}/db/export.yml")


    I18n.locale = 'en'
    records = data['records']
    if records
      puts
      site = (Site.find(ENV['SITE_ID']) if ENV['SITE_ID']) || nil
      records.keys.each do |key|

        begin
          puts "Creating #{key.to_s.underscore.humanize}"
          model = key.singularize.constantize
          test_record = model.new
          record_pairs = records[key]
          record_pairs.each do |id, record|

            # can we handle the attribute?
            record.reject! { |attribute, value|
              unless test_record.respond_to?(attribute.to_sym)
                puts " - deleting #{attribute} from import"
                true
              end
            }
            record.each_key do |attr|
              if (attr.match("_id") && ENV['ID_OFFSET'] && !attr.match(/status|updated_by|created_by|twitter|base_gallery|filter/))
                puts " - ajusting #{attr} + #{ENV['ID_OFFSET']} "
                record[attr] = record[attr].to_i + ENV['ID_OFFSET'].to_i
                if attr.match("parent_id") && record['parent_id'] == ENV['ID_OFFSET'] 
                  puts "the ROOT page is at #{id}"
                  record[attr] = nil
                end
              end
            end
            I18n.locale = 'en'
            r = model.new(record)
            r.id = ENV['ID_OFFSET'] ? (ENV['ID_OFFSET'].to_i + id.to_i) : id

            r.site = site if ((r.respond_to? :site) && site)
            begin
              r.save!
              case model.to_s
                when "Page" then
                  puts "translation for Page"
                  I18n.locale = 'de'
                  r.title = record['title']
                  r.slug = record['slug']
                  r.breadcrumb = record["breadcrumb"]
                  r.description = record["description"]
                  r.keywords = record["keywords" ]
                  r.save!
                when "PagePart", "Snippet", "Layout" then
                  puts "translation for #{model.to_s}"
                  I18n.locale = 'de'
                  r.content = record["content"]
                  r.save!  
              end

            rescue StandardError => e
              puts "Validation Skip #{key.singularize}: #{e.inspect}"
              pp r
            end
            # UserActionObserver sets user to null, so we have to update explicitly
            model.update_all({:created_by_id => ((ENV['CREATED_BY_ID']) ? ENV['CREATED_BY_ID'] : record['created_by_id'])}, {:id => r.id}) if r.respond_to? :created_by_id
            model.update_all({:updated_by_id => ((ENV['CREATED_BY_ID']) ? ENV['CREATED_BY_ID'] : record['created_by_id'])}, {:id => r.id}) if r.respond_to? :updated_by_id
          end
        rescue StandardError => e
          puts "Skip #{key.singularize}: #{e.inspect}"
        end

      end
    end


  end


end