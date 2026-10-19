# Armazenamento de objetos (MinIO, compatível com S3). Em staging e produção as
# quatro variáveis são obrigatórias: o boot cai em vez de gravar em lugar nenhum.
module ObjectStorage
  REQUIRED = %w[MINIO_ENDPOINT MINIO_BUCKET MINIO_ACCESS_KEY_ID MINIO_SECRET_ACCESS_KEY].freeze

  class MissingConfig < StandardError; end

  def self.check!(env: ENV, rails_env: Rails.env)
    return unless %w[staging production].include?(rails_env.to_s)

    missing = REQUIRED.select { |k| env[k].to_s.strip.empty? }
    return if missing.empty?

    raise MissingConfig, "object storage not configured in #{rails_env}: missing #{missing.join(', ')}"
  end
end

ObjectStorage.check!
