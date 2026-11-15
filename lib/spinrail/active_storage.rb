module Spinrail
  # Active Storage on the local disk: Rails' tables (active_storage:install),
  # its key layout under storage/, and blobs served through signed ids.
  # Compiled in only when a model declares an attachment.
  module ActiveStorage
    TABLES = %w[active_storage_blobs active_storage_attachments].freeze

    BLOB = <<~'RUBY'
      class ActiveStorage::Blob < ApplicationRecord
        def self.service = ActiveStorage::DiskService.new(Spinrail.storage_root)

        def self.create_and_upload!(data, filename, content_type)
          blob = new(key: generate_unique_secure_token, filename: filename, content_type: content_type,
                     metadata: "{}", service_name: "local", byte_size: data.bytesize,
                     checksum: Base64.strict_encode64(Digest::MD5.digest(data)))
          ActiveStorage::Blob.service.upload(blob.key, data)
          blob.save!
          blob
        end

        # Rails' format: 28 lowercase base36 characters.
        def self.generate_unique_secure_token
          alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
          token = +""
          SecureRandom.random_bytes(28).each_byte { |b| token << alphabet[b % 36] }
          token
        end

        # Signs the key, not the id: SQLite reuses the id of a deleted row.
        def self.find_signed(signed_id)
          key = Spinrail.verified(signed_id, "blob_id")
          key.empty? ? nil : find_by(key: key)
        end

        def signed_id = Spinrail.signed(key, "blob_id")
        def path = ActiveStorage::Blob.service.path_for(key)
        def download = File.binread(path)
        def image? = content_type.to_s.start_with?("image/")
        def variable? = false
        def to_s = filename.to_s

        def purge
          ActiveStorage::Blob.service.delete(key)
          destroy
        end
      end
    RUBY

    ATTACHMENT = <<~'RUBY'
      class ActiveStorage::Attachment < ApplicationRecord
        def blob = ActiveStorage::Blob.find(blob_id)
      end
    RUBY

    SUPPORT = <<~'RUBY'
      module ActiveStorage
        module Attached
        end
      end

      class ActiveStorage::DiskService
        def initialize(root)
          @root = root
        end

        # Rails' Disk service layout: root/ab/cd/abcd...
        def path_for(key) = @root + "/" + key[0, 2] + "/" + key[2, 2] + "/" + key

        def upload(key, data)
          FileUtils.mkdir_p(@root + "/" + key[0, 2] + "/" + key[2, 2])
          File.binwrite(path_for(key), data)
        end

        def delete(key)
          File.delete(path_for(key)) if File.exist?(path_for(key))
        end

        def exist?(key) = File.exist?(path_for(key))
      end

      # record.avatar: what is attached under one name. Attaching to a record
      # that isn't saved yet waits for its after_save.
      class ActiveStorage::Attached::One
        attr_accessor :record_id

        def initialize(name, record_type, record_id)
          @name = name
          @record_type = record_type
          @record_id = record_id
          @pending = false
          @pending_data = ""
          @pending_filename = ""
          @pending_type = ""
          @loaded = false
          @attachment = nil
        end

        def attach(file)
          attach_data(file.read, file.original_filename, file.content_type)
        end

        def attach_data(data, filename, content_type)
          assign_data(data, filename, content_type)
          save_pending(@record_id) if @record_id > 0
          true
        end

        # record.avatar = file: stored when the record saves.
        def assign(file) = assign_data(file.read, file.original_filename, file.content_type)

        def assign_data(data, filename, content_type)
          @pending = true
          @pending_data = data
          @pending_filename = filename
          @pending_type = content_type
        end

        def save_pending(record_id)
          return unless @pending
          @record_id = record_id
          @pending = false
          purge
          blob = ActiveStorage::Blob.create_and_upload!(@pending_data, @pending_filename, @pending_type)
          @pending_data = ""
          @attachment = ActiveStorage::Attachment.create!(name: @name, record_type: @record_type, record_id: @record_id, blob_id: blob.id)
          @loaded = true
        end

        def attachment
          unless @loaded
            @attachment = @record_id > 0 ? ActiveStorage::Attachment.find_by(record_type: @record_type, record_id: @record_id, name: @name) : nil
            @loaded = true
          end
          @attachment
        end

        def attached? = @pending || !attachment.nil?

        def blob
          found = attachment
          raise Spinrail::RecordNotFound, "nothing attached as " + @name if found.nil?
          found.blob
        end

        def filename = blob.filename
        def content_type = blob.content_type
        def byte_size = blob.byte_size
        def checksum = blob.checksum
        def key = blob.key
        def signed_id = blob.signed_id
        def download = blob.download
        def image? = attached? && blob.image?
        def variable? = false
        def to_s = attached? ? blob.filename.to_s : ""

        def purge
          found = attachment
          return if found.nil?
          blob = found.blob
          found.destroy
          blob.purge
          @attachment = nil
        end

        def purge_later = purge
        def detach = purge
      end
    RUBY

    # Rails serves these inline; anything else downloads, and types a browser
    # could run as script are sent as binary.
    INLINE = %w[image/png image/gif image/jpeg image/tiff image/vnd.adobe.photoshop
                image/vnd.microsoft.icon image/webp image/avif image/heic image/heif application/pdf].freeze
    BINARY = %w[text/html application/xhtml+xml text/javascript text/xml application/xml image/svg+xml].freeze

    HELPERS = <<~RUBY
      def rails_blob_path(attachable, disposition: "")
        "/rails/active_storage/blobs/proxy/" + attachable.signed_id + "/" + Spinrail.escape_path(attachable.filename.to_s) +
          (disposition.to_s.empty? ? "" : "?disposition=" + disposition.to_s)
      end

      def rails_blob_url(attachable, disposition: "") = request_base_url + rails_blob_path(attachable, disposition: disposition)
    RUBY

    ROUTE = <<~RUBY
      get %r{/rails/active_storage/blobs/(?:proxy|redirect)/([^/]+)/(.+)} do
        signed_id = req.params.fetch("1", "")
        request_id = Spinrail.request_id(req)
        res.headers["X-Request-Id"] = request_id
        Spinrail.log.start(req.verb, req.path, "ActiveStorage::Blobs::ProxyController#show", request_id, req.params, req.ip)
        c = Spinrail::Controller.new(req, res)
        blob = ActiveStorage::Blob.find_signed(signed_id)
        if blob.nil? || !ActiveStorage::Blob.service.exist?(blob.key)
          c.head(404)
        else
          type = blob.content_type.to_s
          type = "application/octet-stream" if type.empty? || #{BINARY.inspect}.include?(type)
          inline = req.params.fetch("disposition", "") != "attachment" && #{INLINE.inspect}.include?(type)
          res.headers["Cache-Control"] = "max-age=3155695200, public, immutable"
          c.send_file(blob.path, type, inline ? "inline" : "attachment", blob.filename.to_s)
        end
        Spinrail.log.finish(res.status)
        c.response_body
      end
    RUBY

    def self.source(schema)
      raise CompileError, "has_one_attached needs the #{TABLES.join(' and ')} tables (bin/rails active_storage:install's migration)" unless TABLES.all? { |t| schema.table(t) }

      "module ActiveStorage\nend\n\n" + yield(BLOB, "active_storage_blobs", "active_storage/blob.rb") + "\n" +
        yield(ATTACHMENT, "active_storage_attachments", "active_storage/attachment.rb") + "\n" + SUPPORT
    end
  end
end
