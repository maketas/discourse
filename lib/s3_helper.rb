require "aws-sdk-s3"

class S3Helper

  class SettingMissing < StandardError; end

  attr_reader :s3_bucket_name

  def initialize(s3_upload_bucket, tombstone_prefix = '', options = {})
    @s3_options = default_s3_options.merge(options)

    @s3_bucket_name, @s3_bucket_folder_path = begin
      raise Discourse::InvalidParameters.new("s3_bucket") if s3_upload_bucket.blank?
      s3_upload_bucket.downcase.split("/".freeze, 2)
    end

    @tombstone_prefix =
      if @s3_bucket_folder_path
        File.join(@s3_bucket_folder_path, tombstone_prefix)
      else
        tombstone_prefix
      end

    check_missing_options
  end

  def upload(file, path, options = {})
    path = get_path_for_s3_upload(path)
    obj = s3_bucket.object(path)
    obj.upload_file(file, options)
    path
  end

  def remove(s3_filename, copy_to_tombstone = false)
    bucket = s3_bucket

    # copy the file in tombstone
    if copy_to_tombstone && @tombstone_prefix.present?
      bucket
        .object(File.join(@tombstone_prefix, s3_filename))
        .copy_from(copy_source: File.join(@s3_bucket_name, get_path_for_s3_upload(s3_filename)))
    end

    # delete the file
    bucket.object(get_path_for_s3_upload(s3_filename)).delete
  rescue Aws::S3::Errors::NoSuchKey
  end

  def update_lifecycle(id, days, prefix: nil)

    # cf. http://docs.aws.amazon.com/AmazonS3/latest/dev/object-lifecycle-mgmt.html
    rule = {
      id: id,
      status: "Enabled",
      expiration: { days: days }
    }

    if prefix
      rule[:prefix] = prefix
    end

    rules = s3_resource.client.get_bucket_lifecycle_configuration(bucket: @s3_bucket_name).rules

    rules.delete_if do |r|
      r.id == id
    end

    rules.map! { |r| r.to_h }

    rules << rule

    s3_resource.client.put_bucket_lifecycle(bucket: @s3_bucket_name,
                                            lifecycle_configuration: {
        rules: rules
    })
  end

  def update_tombstone_lifecycle(grace_period)
    return if @tombstone_prefix.blank?
    update_lifecycle("purge_tombstone", grace_period, prefix: @tombstone_prefix)
  end

  def list
    s3_bucket.objects(prefix: @s3_bucket_folder_path)
  end

  def tag_file(key, tags)
    tag_array = []
    tags.each do |k, v|
      tag_array << { key: k.to_s, value: v.to_s }
    end

    s3_resource.client.put_object_tagging(
      bucket: @s3_bucket_name,
      key: key,
      tagging: {
        tag_set: tag_array
      }
    )
  end

  private

  def get_path_for_s3_upload(path)
    path = File.join(@s3_bucket_folder_path, path) if @s3_bucket_folder_path
    path
  end

  def default_s3_options
    opts = { region: SiteSetting.s3_region }

    unless SiteSetting.s3_use_iam_profile
      opts[:access_key_id] = SiteSetting.s3_access_key_id
      opts[:secret_access_key] = SiteSetting.s3_secret_access_key
    end

    opts
  end

  def s3_resource
    Aws::S3::Resource.new(@s3_options)
  end

  def s3_bucket
    bucket = s3_resource.bucket(@s3_bucket_name)
    bucket.create unless bucket.exists?
    bucket
  end

  def check_missing_options
    unless SiteSetting.s3_use_iam_profile
      raise SettingMissing.new("access_key_id") if @s3_options[:access_key_id].blank?
      raise SettingMissing.new("secret_access_key") if @s3_options[:secret_access_key].blank?
    end
  end
end
