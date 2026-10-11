require "zlib"
require_relative "signature_crew"
require_relative "digital_signature_crew"

# Semente de dev do 19d (ADR 0034). Dev é fictício mas imita o real: só
# Curitiba liga, e liga os DOIS interruptores (controlled_prescriptions e o
# SNCR simulado sncr_mock) com o mantenedor de dev, pelo mesmo caminho do
# maintenance; o dentista da APS (CRO, CBO 223208) com TOTP fixo; endereço e
# telefone de prescritor da médica e do dentista (gravados pela mesma
# normalização da API, sem máscara); um bloco SIMULADO de 1.000 RCE e 1.000 RET
# da médica. Roda depois do DigitalSignatureCrew e do ClinicalDocumentsCrew.
# Idempotente.
module ControlledPrescriptionsCrew
  DEV_MAINTAINER = "dev@local".freeze
  SWITCHES = %w[controlled_prescriptions sncr_mock].freeze
  UNIT = "UBS Jardim das Flores".freeze
  DENTIST = { prefix: "dentista", name: "Marcos Vinícius Teixeira", cbo: "223208",
              secret_env: "DEV_DENTIST_OTP_SECRET", default_secret: "MRSW45DJON2GC5DFON2GCZDFEBZG65DB" }.freeze
  ADDRESS = { "street" => "Rua Desembargador Westphalen", "number" => "1500", "complement" => "sala 4", "district" => "Rebouças",
              "city" => "Curitiba", "uf" => "PR", "zip" => "80230100" }.freeze
  PHONES = { "profissional" => "4132221100", "dentista" => "4132221101" }.freeze

  module_function

  def seed_current_city(slug:, password:, admin:)
    return { switch: "desligado (só Curitiba liga)" } unless slug == "curitiba"

    maintainer = Maintainer.find_by(email_address: DEV_MAINTAINER)
    unless maintainer
      warn "[seeds] receita controlada: sem mantenedor de dev (#{DEV_MAINTAINER}) — interruptores não ligados"
      return { switch: "desligado (sem mantenedor)" }
    end

    city = City.find(Current.city.id)
    SWITCHES.each { |key| Platform::Features.set!(city: city, key: key, enabled: true, maintainer: maintainer) }
    dentist = ensure_dentist(slug: slug, password: password, admin: admin)
    doctor = User.find_by!(email_address: "profissional@#{slug}.demo")
    { "profissional" => doctor, "dentista" => dentist }.each do |prefix, user|
      next if user.professional.prescriber_contact

      address, field = ClinicalDocuments::Address.normalize(ADDRESS)
      raise "semente: endereço de prescritor inválido (#{field})" if field

      user.professional.update!(prescriber_address: address.to_json, phone: PHONES.fetch(prefix))
    end
    missing = SWITCHES.flat_map { |key| Platform::Features.missing(city, key) }
    { switch: missing.empty? ? "ligado" : "ligado, falta: #{missing.join(', ')}", dentist: dentist.email_address,
      contacts: 2, block: ensure_block(doctor) }
  end

  def ensure_dentist(slug:, password:, admin:)
    user = User.find_or_initialize_by(email_address: "#{DENTIST[:prefix]}@#{slug}.demo")
    user.password = password
    user.save!
    Membership.find_or_create_by!(user: user, role: "health_professional") { |membership| membership.granted_at = Time.current }
    SignatureCrew.ensure_totp(user, secret_env: DENTIST[:secret_env], default_secret: DENTIST[:default_secret])
    unless user.professional
      seed = "#{slug}:#{DENTIST[:prefix]}"
      attrs = { professional_name: DENTIST[:name], council: "CRO", council_state: CityProfile.current&.uf.presence || "PR",
                cns: Professionals::Cns.generate(seed), registration_number: (Zlib.crc32(seed) % 90_000 + 10_000).to_s }
      result = Professionals::Create.call(user_id: user.id, attrs: attrs, by: admin)
      raise "semente: perfil do dentista recusado (#{result.reason})" if result.failure?

      user.reload
    end
    user.professional.update!(cpf: DigitalSignatureCrew.free_cpf_for(slug, user.professional)) if user.professional.cpf.blank?
    unit = HealthUnit.find_by!(name: UNIT)
    unless user.professional.links.active.exists?(health_unit_id: unit.id, cbo_code: DENTIST[:cbo])
      result = Professionals::OpenLink.call(professional: user.professional, health_unit_id: unit.id, cbo_code: DENTIST[:cbo], by: admin)
      raise "semente: vínculo do dentista recusado (#{result.reason})" if result.failure?
    end
    user
  end

  # Um bloco simulado de 1.000 por tipo, só se o prescritor NÃO tem número
  # LIVRE desse tipo no simulado (com estoque livre, não gasta cota: cada bloco
  # conta como 1 pedido do mês, como um pedido de verdade). Os blocos da semente
  # ocupam as faixas 0..99 do mês (sequência 0000001..0100000); o fake-sncr
  # começa do bloco 100 em diante: não colide. Depois de esgotar, o próximo
  # bloco da semente vem na faixa seguinte (o ON CONFLICT do estoque absorveria
  # uma faixa repetida e o prescritor ficaria sem número).
  SEED_BLOCKS = 100
  BLOCK = 1000

  def ensure_block(doctor)
    granted = %w[rce ret].reject do |kind|
      next true if SncrNumber.available.exists?(user_id: doctor.id, kind: kind, simulated: true)

      prefix = "#{Time.zone.today.strftime('%y%m')}.#{kind == 'rce' ? 1 : 2}-41."
      index = next_seed_block(kind, prefix)
      first, last = [ (index * BLOCK) + 1, (index + 1) * BLOCK ].map { |seq| "#{prefix}#{format('%07d', seq)}" }
      Sncr::Stock.record_batch!(user: doctor, kind: kind, block: Sncr::Client::Block.new(first: first, last: last, quantity: BLOCK),
                                simulated: true)
      false
    end
    granted.empty? ? "já tinha" : "#{granted.map { |kind| "1.000 #{kind.upcase}" }.join(' + ')} simulados"
  end

  # A faixa seguinte à maior sequência simulada da semente neste mês e tipo.
  def next_seed_block(kind, prefix)
    top = SncrNumber.where(kind: kind, simulated: true).where("number LIKE ?", "#{prefix}%")
                    .where("right(number, 7)::int <= ?", SEED_BLOCKS * BLOCK).maximum(Arel.sql("right(number, 7)::int"))
    index = top ? ((top - 1) / BLOCK) + 1 : 0
    raise "semente: faixas simuladas do mês esgotadas" if index >= SEED_BLOCKS

    index
  end
end
