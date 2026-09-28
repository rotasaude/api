require "digest"

# Semente de dev do módulo 11 (spec 2026-09-28-module-11-territory §8). Dev é
# fictício, mas imita o real: os bairros são reais (vêm de db/seeds/territory
# pelo Territory::Seed, que roda ANTES), as unidades da semente de dev ganham
# endereço com CEP real do bairro onde ficam, e os cidadãos de demonstração
# têm bairros variados — um bairro com 5 ou mais casos (o painel mostra o
# número), outros com 1 a 4 (o painel mostra "< 5"), um bairro sem cobertura
# (sem unidade de referência) e alguns sem bairro ("Sem bairro"). Tudo pelos
# comandos do domínio: a triagem copia o bairro no StartTriage, como em
# produção. Idempotente; não sobrescreve endereço já preenchido.
class TerritoryCrew
  UNIT_ADDRESSES = {
    "curitiba" => {
      "UBS Jardim das Flores" => { street: "Avenida Manoel Ribas", number: "5000", zip: "82400000",
                                   neighborhood: "Santa Felicidade" },
      "UBS Vila Esperança" => { street: "Avenida Marechal Floriano Peixoto", number: "6601", zip: "81650000",
                                neighborhood: "Boqueirão" },
      "UPA 24h Centro" => { street: "Rua XV de Novembro", number: "500", zip: "80020310", neighborhood: "Centro" }
    },
    "maringa" => {
      "UPA 24h Centro" => { street: "Avenida Brasil", number: "3000", zip: "87013000", neighborhood: "Zona 01" },
      "UBS Jardim das Flores" => { street: "Avenida Pedro Taques", number: "800", zip: "87030000",
                                   neighborhood: "Zona 07" },
      "UBS Vila Esperança" => { street: "Avenida Morangueira", number: "1200", zip: "87033070",
                                neighborhood: "Jardim Alvorada" }
    }
  }.freeze

  # [bairro (nil = prefere não informar), quantos cidadãos]
  CITIZENS = {
    "curitiba" => [ [ "Santa Felicidade", 6 ], [ "Boqueirão", 3 ], [ "Centro", 1 ], [ "Batel", 2 ], [ nil, 3 ] ],
    "maringa" => [ [ "Zona 07", 5 ], [ "Jardim Alvorada", 2 ], [ "Zona 01", 1 ], [ nil, 2 ] ]
  }.freeze

  # Alterna triagem alta (tosse e febre) e baixa (sem tosse).
  ANSWERS = [ %w[true true], %w[false] ].freeze

  class << self
    def seed_current_city(slug:, ddd:)
      addressed = UNIT_ADDRESSES.fetch(slug, {}).count { |unit_name, address| ensure_address(unit_name, address) }
      people = CITIZENS.fetch(slug, []).flat_map { |name, n| Array.new(n, name) }
      new_triages = people.each_with_index.count { |neighborhood_name, i| ensure_citizen(slug, ddd, i, neighborhood_name) }
      { units_with_address: addressed, citizens: people.size, new_triages: new_triages }
    end

    private

    # true quando a unidade existe (com endereço novo ou já preenchido).
    def ensure_address(unit_name, address)
      unit = HealthUnit.find_by(name: unit_name)
      return false unless unit
      return true if unit.address_street.present?

      neighborhood = Neighborhood.named(address[:neighborhood]).first
      unit.update!(address_street: address[:street], address_number: address[:number], address_zip: address[:zip],
                   neighborhood: neighborhood)
      true
    end

    # true quando criou a triagem agora.
    def ensure_citizen(slug, ddd, index, neighborhood_name)
      registered = Citizens::RegisterPerson.call(phone: format("+55%s97777%04d", ddd, index + 1),
                                                 cpf: cpf_for("#{slug}:territory:#{index}"))
      raise "semente: cidadão recusado (#{registered.reason})" if registered.failure?

      citizen = registered.payload[:citizen]
      return false if Triage.joins(:conversation).where(conversations: { citizen_id: citizen.id }).exists?

      if neighborhood_name
        neighborhood = Neighborhood.named(neighborhood_name).first ||
                       raise("semente: bairro #{neighborhood_name} ausente (rode Territory::Seed antes)")
        Citizens::SetNeighborhood.call(citizen: citizen, neighborhood_id: neighborhood.id)
      end

      started = Citizens::StartConversation.call(citizen: citizen, consent_version: Consents.current_version,
                                                 session_id: "seed-territory")
      raise "semente: conversa recusada (#{started.reason})" if started.failure?

      ANSWERS[index % ANSWERS.size].each_with_index do |answer, step|
        Citizens::SubmitAnswer.call(conversation: started.payload[:conversation], answer: answer,
                                    idempotency_key: "seed-territory-#{slug}-#{index}-#{step}")
      end
      true
    end

    # CPF com dígitos verificadores válidos, determinístico pela semente.
    def cpf_for(seed)
      base = Digest::SHA256.hexdigest(seed).scan(/\d/).join[0, 9].ljust(9, "7")
      nums = base.chars.map(&:to_i)
      first = CitizenIdentity::Cpf.check_digit(nums)
      second = CitizenIdentity::Cpf.check_digit(nums + [ first ])
      "#{base}#{first}#{second}"
    end
  end
end
