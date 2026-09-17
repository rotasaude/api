# Token de serviço da API de manutenção (spec §7): a credencial da AUTOMAÇÃO.
#
# Três decisões que este arquivo sustenta:
#
#   1. O segredo nunca é gravado. `issue!` devolve o par [registro, segredo] e
#      o segredo some do processo depois da resposta; a busca é sempre por
#      digest.
#   2. O digest é HMAC com o secret_key_base DO AMBIENTE. Como cada ambiente tem
#      credentials próprias (Plano 1), um token de staging não valida em
#      development nem que alguém troque o prefixo — o isolamento não depende só
#      do prefixo, que é texto. Rotacionar secret_key_base invalida todos os
#      tokens, de propósito.
#   3. Validade é obrigatória e tem teto. Um token sem expiração é uma conta de
#      superusuário que ninguém revoga porque ninguém lembra que ela existe.
class MaintenanceToken < PlatformRecord
  belongs_to :maintainer

  ACCESS = %w[read read_write].freeze
  MAX_TTL = 90.days
  SECRET_BYTES = 32

  validates :name, presence: true
  validates :access, inclusion: { in: ACCESS }
  validates :expires_at, presence: true
  validate :expiry_within_ceiling

  scope :live, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  # rsm_dev_ / rsm_stg_ / rsm_test_: `Rails.env.first(N)` não dá essas siglas (
  # "staging".first(3) é "sta", não "stg"), então o mapa é explícito. Ambiente
  # fora do mapa (produção, onde a API nem liga) cai no nome cheio — nunca
  # colide com os três de cima.
  PREFIX_BY_ENV = { "development" => "dev", "staging" => "stg", "test" => "test" }.freeze

  class << self
    # Prefixo por ambiente: dá para reconhecer o token num incidente e cadastrar
    # o padrão no secret scanning do GitHub (os repositórios são públicos).
    def prefix = "rsm_#{PREFIX_BY_ENV.fetch(Rails.env.to_s, Rails.env.to_s)}_"

    def digest_for(secret)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s, secret.to_s)
    end

    def issue!(maintainer:, name:, access:, city_slugs:, expires_at:)
      secret = "#{prefix}#{SecureRandom.urlsafe_base64(SECRET_BYTES)}"
      token = create!(maintainer: maintainer, name: name.to_s.strip, access: access,
                      city_slugs: Array(city_slugs).map(&:to_s), expires_at: expires_at,
                      token_digest: digest_for(secret), token_prefix: prefix)
      [ token, secret ]
    end

    # Recusa o prefixo de outro ambiente ANTES de consultar o banco: um token de
    # staging apresentado em development nem chega a virar query.
    def authenticate(secret)
      secret = secret.to_s
      return nil unless secret.start_with?(prefix)

      token = find_by(token_digest: digest_for(secret))
      return nil unless token&.usable?

      token
    end
  end

  def usable? = revoked_at.nil? && expires_at > Time.current && maintainer.active?

  def read_only? = access == "read"

  # Lista vazia = todas as cidades. O predicado existe desde já, mas só ganha
  # chamador no Plano 4, quando o schema tiver `city(slug:)`.
  def allows_city?(slug) = city_slugs.empty? || city_slugs.include?(slug.to_s)

  def touch_use!(ip:)
    update_columns(last_used_at: Time.current, last_used_ip: ip)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  private

  def expiry_within_ceiling
    return if expires_at.blank?

    errors.add(:expires_at, "além do teto de #{MAX_TTL.inspect}") if expires_at > MAX_TTL.from_now
    errors.add(:expires_at, "já passou") if expires_at <= Time.current
  end
end
