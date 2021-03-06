module Azure::Armrest::Storage::ManagedStorageHelper
  require_relative 'managed_disk'
  # Get the raw blob information for a managed disk. This is similar to
  # the StorageAccount#get_blob_raw method, but applies only to a managed
  # disk or its snapshot, whereas that method applies only to an individual storage
  # account.
  #
  # As with the Storage#get_blob_raw method, you should pass a :range,
  # :start_byte, :end_byte or :length option. If you want the entire
  # image you must pass the :entire_image option, though this is generally
  # not recommended. Unlike the Storage#get_blob_raw method, this method
  # does not support the :date parameter.
  #
  # The +options+ are as follows:
  #
  #   :range        => A range of bytes you want, e.g. 0..1023 to get first 1k bytes
  #   :start_byte   => The starting byte number that you want to collect bytes for. Use
  #                    this in conjunction with :length or :end_byte.
  #   :end_byte     => The ending byte that you want to collect bytes for. Use this
  #                    in conjunction with :start_byte.
  #   :length       => If given a :start_byte, specifies the number of bytes from the
  #                    the :start_byte that you wish to collect.
  #   :entire_image => If set, returns the entire image in bytes. This will be a long
  #                    running request that returns a large number of bytes.
  #
  # You may also pass a :duration parameter, which indicates how long, in
  # seconds, that the privately generated SAS token should last. This token
  # is used internally by requests that are used to access the requested
  # information. By default it lasts for 1 hour.
  #
  # Get the information you need using:
  #
  # * response.body    - blob data (the raw bytes).
  # * response.headers - blob metadata (a hash).
  #
  # Example:
  #
  #   vms = Azure::Armrest::VirtualMachineService.new(conf)
  #   sds = Azure::Armrest::Storage::DiskService.new(conf)
  #
  #   vm = vms.get(vm_name, vm_resource_group)
  #   os_disk = vm.properties.storage_profile.os_disk
  #
  #   disk_id = os_disk.managed_disk.id
  #   disk = sds.get_by_id(disk_id)
  #
  #   # Get the first 1024 bytes
  #   data = sds.get_blob_raw(disk.name, disk.resource_group, :range => 0..1023)
  #
  #   p data.headers
  #   File.open('vm.vhd', 'a'){ |fh| fh.write(data.body) }
  #
  def open(disk_name, resource_group = configuration.resource_group, options = {})
    ManagedDisk.new(self, disk_name, resource_group, options)
  end

  def read(sas_url, options = {})
    # The same restrictions that apply to the StorageAccount method also apply here.
    range = options[:range] if options[:range]
    range ||= options[:start_byte]..options[:end_byte] if options[:start_byte] && options[:end_byte]
    range ||= options[:start_byte]..options[:start_byte] + options[:length] - 1 if options[:start_byte] && options[:length]

    range_str = range ? "bytes=#{range.min}-#{range.max}" : nil

    unless range_str || options[:entire_image]
      raise ArgumentError, "must specify byte range or :entire_image flag"
    end

    headers = {}
    headers['x-ms-range'] = range_str if range_str

    # Need to make a raw call since we need to explicitly pass headers,
    # but without encoding the URL or passing our configuration token.
    max_retries           = 5
    retries               = 0

    begin
      RestClient::Request.execute(
        :method      => :get,
        :url         => sas_url,
        :headers     => headers,
        :proxy       => configuration.proxy,
        :ssl_version => configuration.ssl_version,
        :ssl_verify  => configuration.ssl_verify
      )
    rescue Azure::Armrest::ForbiddenException => err
      log('warn', "ManagedStorageHelper.read: #{err}")
      raise err
    rescue RestClient::Exception, Azure::Armrest::ForbiddenException => err
      raise err unless retries < max_retries
      log('warn', "ManagedStorageHelper.read: #{err} - retry number #{retries}")
      retries += 1
      sleep 5
      retry
    end
  end

  def close(disk_name, resource_group)
    end_url = build_url(resource_group, disk_name, 'EndGetAccess')
    rest_post(end_url)
  end

  def get_blob_raw(disk_name, resource_group = configuration.resource_group, options = {})
    managed_disk = open(disk_name, resource_group, options)
    begin
      managed_disk.read(options)
    ensure
      managed_disk.close
    end
  end

  def access_token(disk_name, resource_group = configuration.resource_group, options = {})
    validate_resource_group(resource_group)

    post_options = {
      :access            => 'read',                    # Must be 'read'
      :durationInSeconds => options[:duration] || 3600 # 1 hour default
    }

    # This call will give us an operations URL in the headers.
    begin_get_access_url = build_url(resource_group, disk_name, 'BeginGetAccess')
    begin_get_access_response = rest_post(begin_get_access_url, post_options.to_json)

    headers = Azure::Armrest::ResponseHeaders.new(begin_get_access_response.headers)
    status = wait(headers, 120, 1)

    unless status.casecmp('succeeded').zero?
      msg = "Unable to obtain an operations URL for #{disk_name}/#{resource_group}"
      log('debug', "#{msg}: #{begin_get_access_response.headers}")
      raise Azure::Armrest::NotFoundException.new(begin_get_access_response.code, msg, begin_get_access_response.body)
    end

    # Get the SAS URL from the BeginGetAccess call
    op_url = headers.try(:azure_asyncoperation) || headers.location

    # Dig the URL + SAS token URL out of the response
    response = rest_get(op_url)
    body     = Azure::Armrest::ResponseBody.new(response.body)
    body.properties.output.access_sas
  end
end
