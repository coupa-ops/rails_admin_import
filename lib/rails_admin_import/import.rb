require 'open-uri'
  
module RailsAdminImport
  module Import
    extend ActiveSupport::Concern
  
    module ClassMethods
      def file_fields
        attrs = []
        if self.methods.include?(:attachment_definitions) && !self.attachment_definitions.nil?
          attrs = self.attachment_definitions.keys
        end
        attrs - RailsAdminImport.config(self).excluded_fields 
      end
  
      def import_fields
        fields = []  

        fields = self.new.attributes.keys.collect { |key| key.to_sym }
  
        self.belongs_to_fields.each do |key|
          fields.delete("#{key}_id".to_sym)
          fields.delete("#{key}_type".to_sym)
        end
  
        self.file_fields.each do |key|
          fields.delete("#{key}_file_name".to_sym)
          fields.delete("#{key}_content_type".to_sym)
          fields.delete("#{key}_file_size".to_sym)
          fields.delete("#{key}_updated_at".to_sym)
        end
 
        excluded_fields = RailsAdminImport.config(self).excluded_fields 
        [:id, :created_at, :updated_at, excluded_fields].flatten.each do |key|
          fields.delete(key)
        end
  
        fields
      end
 
      def belongs_to_fields
        attrs = self.reflections.select { |k, v| v.macro == :belongs_to }.keys
        attrs - RailsAdminImport.config(self).excluded_fields 
      end
  
      def many_fields
        attrs = []
        self.reflections.each do |k, v|
          if [:has_and_belongs_to_many, :has_many].include?(v.macro)
            attrs << k.to_s.singularize.to_sym
          end
        end

        attrs - RailsAdminImport.config(self).excluded_fields 
      end 

      def all_polymorphic_types(name)
        @poly_hash ||= {}.tap do |hash|
          Dir.glob(File.join(Rails.root, "app", "models", "**", "*.rb")).each do |file|
            klass = (File.basename(file, ".rb").camelize.constantize rescue nil)
            next if klass.nil? or !klass.ancestors.include?(ActiveRecord::Base)
            klass.reflect_on_all_associations(:has_many).select{|r| r.options[:as] }.each do |reflection|
              (hash[reflection.options[:as]] ||= []) << klass
            end
          end
        end
        @poly_hash[name.to_sym]
      end
  
      def run_import(params)
        logger = nil
        begin
          if !params.has_key?(:file)
            return results = { :success => [], :error => ["You must select a file."] }
          end

          if RailsAdminImport.config.logging
            FileUtils.copy(params[:file].tempfile, "#{Rails.root}/log/import/#{Time.now.strftime("%Y-%m-%d-%H-%M-%S")}-import.csv")
            logger = Logger.new("#{Rails.root}/log/import/import.log")
          end

          text = File.read(params[:file].tempfile)
          clean = text.force_encoding('BINARY').encode('UTF-8', :undef => :replace, :replace => '').gsub(/\n$/, '').gsub(/ *, */, ',')
          clean.downcase!
          file_check = CSV.new(clean)

          if file_check.readlines.size > RailsAdminImport.config.line_item_limit
            return results = { :success => [], :error => ["Please limit upload file to #{RailsAdminImport.config.line_item_limit} line items."] }
          end
  
          map = {}
   
          file = CSV.new(clean)
          file.readline.each_with_index do |l, i|
            key = l.underscore.gsub(/\s/, '_')
            if self.many_fields.include?(key.to_sym)
              map[key.to_sym] ||= []
              map[key.to_sym] << i
            else
              map[key.to_sym] = i 
            end
          end
   
          update = params.has_key?(:update_if_exists) && params[:update_if_exists] ? params[:update_lookup].to_sym : nil
  
          if update && !map.has_key?(params[:update_lookup].to_sym)
            return results = { :success => [], :error => ["Your file must contain a column for the 'Update lookup field' you selected."] }
          end 
    
          results = { :success => [], :error => [] }

          label_method = RailsAdminImport.config(self).label
  
          file.each do |row|
            object = self.import_initialize(row, map, update)
            object.import_belongs_to_data(row, map, params)
            object.import_many_data(row, map, params)
            object.before_import_save(row, map)
  
            object.import_files(row, map)
  
            verb = object.new_record? ? "Create" : "Update"
            if object.errors.empty?
              if object.save
                logger.info "#{Time.now.to_s}: #{verb}d: #{object.send(label_method)}" if logger
                results[:success] << "#{verb}d: #{object.send(label_method)}"
              else
                logger.info "#{Time.now.to_s}: Failed to #{verb}: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}." if logger
                results[:error] << "Failed to #{verb}: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}."
              end
            else
              logger.info "#{Time.now.to_s}: Errors before save: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}." if logger
              results[:error] << "Errors before save: #{object.send(label_method)}. Errors: #{object.errors.full_messages.join(', ')}."
            end
          end
    
          results
        rescue Exception => e
          logger.info "#{Time.now.to_s}: Unknown exception in import: #{e.inspect}#{e.backtrace.join("\n")}" if logger
          return results = { :success => [], :error => ["Could not upload. Unexpected error: #{e.to_s}"] }
        end
      end
  
      def import_initialize(row, map, update)
        new_attrs = {}
        self.import_fields.each do |key|
          new_attrs[key] = row[map[key]] if map[key]
        end

        item = nil
        if update.present?
          item = self.send("find_by_#{update}", row[map[update]])
        end 

        if item.nil?
          item = self.new(new_attrs)
        else
          item.attributes = new_attrs.except(update.to_sym)
          item.save
        end

        item
      end
    end
   
    def before_import_save(*args)
      # Meant to be overridden to do special actions
    end

    def import_display
      self.id
    end

    def import_files(row, map)
      if self.new_record? && self.valid?
        self.class.file_fields.each do |key|
          if map[key] && !row[map[key]].nil?
            begin
              # Strip file
              row[map[key]] = row[map[key]].gsub(/\s+/, "")
              format = row[map[key]].match(/[a-z0-9]+$/)
              open("#{Rails.root}/tmp/#{self.permalink}.#{format}", 'wb') { |file| file << open(row[map[key]]).read }
              self.send("#{key}=", File.open("#{Rails.root}/tmp/#{self.permalink}.#{format}"))
            rescue Exception => e
              self.errors.add(:base, "Import error: #{e.inspect}")
            end
          end
        end
      end
    end

    def import_belongs_to_data(row, map, params)
      self.class.belongs_to_fields.each do |key|
        assoc_key = params[key.to_s]
        if map.has_key?(key) && row[map[key]] != ""
          self.send("#{key}=", find_assoc_obj(key, assoc_key, row[map[key]]))
        end
      end
    end

    def import_many_data(row, map, params)
      self.class.many_fields.each do |key|
        values = []
        assoc_key = params[key.to_s]

        map[key] ||= []
        map[key].each do |pos|
          if row[pos] != ""
            if obj = find_assoc_obj(key, assoc_key, row[pos])
              values << obj
            end
          end
        end

        if values.any?
          self.send("#{key.to_s.pluralize}=", values)
        end
      end
    end

    def find_assoc_obj(key, assoc_key, value)
      if assoc_key.index('.')
        # polymorphic
        model, field = assoc_key.split('.')
        obj = model.classify.constantize.where(:"#{field}" => value).first
      else
        field = assoc_key
        obj = key.to_s.classify.constantize.where(:"#{field}" => value).first
      end
    end
  end
end

class ActiveRecord::Base
  include RailsAdminImport::Import
end
