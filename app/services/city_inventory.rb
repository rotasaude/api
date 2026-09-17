# Levantamento de configuração de todas as cidades registradas, para a tela de
# manutenção de development (GET /manutencao, dev-only).
#
# Por que é uma classe e não lógica no controller: a rota da tela só existe em
# development, então nenhum request spec a alcança — a suíte roda em test. A
# inteligência mora aqui, onde spec/services/city_inventory_spec.rb chega nela
# sem rota nenhuma, e o controller fica com três linhas.
#
# DUAS REGRAS QUE ESTE ARQUIVO EXISTE PARA SUSTENTAR:
#
#   1. Nada de segredo, nada de cidadão. `database_url` e `encryption_key`
#      (City) e `access_token` (CityChannel) são cifrados com a chave da
#      PLATAFORMA e não entram — nem mascarados, simplesmente ausentes. Telefone,
#      mensagem e evidência de consentimento são dados do cidadão: saem como
#      CONTAGEM, nunca como conteúdo. Uma tela de manutenção que acumula "só
#      mais um campo" vira uma tela de vigilância.
#
#   2. Cidade fora do ar não derruba o levantamento. É quando algo quebrou que a
#      tela precisa abrir — então cada cidade é sondada isoladamente e a falha
#      vira uma linha marcada, com o motivo, ao lado das que responderam.
#
# Custo: o lado da plataforma é uma query só; o lado da cidade abre UMA CONEXÃO
# POR CIDADE. É aceitável numa ferramenta de dev com um punhado de cidades e
# seria inaceitável em qualquer coisa servida a usuário.
module CityInventory
  # Status sem banco para conectar: offboarding apaga banco e role, então
  # tentar é garantia de erro — e erro previsto não é diagnóstico.
  SKIPPED_STATUSES = %w[archived].freeze

  module_function

  def call
    City.order(:slug).map { |city| entry_for(city) }
  end

  def entry_for(city)
    base = {
      slug: city.slug,
      name: city.name,
      uf: city.uf,
      status: city.status,
      schema_version: city.schema_version,
      expected_version: CitySchema.expected_version,
      behind: CitySchema.behind?(city),
      channel: channel_for(city),
      created_at: city.created_at,
      updated_at: city.updated_at
    }

    base.merge(city_side_for(city))
  end

  # Canal do WhatsApp: mora na PLATAFORMA, ao lado do catálogo, então sai sem
  # abrir conexão de cidade. O access_token fica de fora de propósito.
  def channel_for(city)
    channel = CityChannel.where(city_id: city.id).order(active: :desc, created_at: :desc).first
    return nil if channel.nil?

    {
      phone_number_id: channel.phone_number_id,
      waba_id: channel.waba_id,
      display_phone_number: channel.display_phone_number,
      active: channel.active
    }
  end

  # O lado de dentro do banco da cidade. Todo o corpo é sondagem: qualquer
  # erro daqui é informação de diagnóstico, não motivo para a página falhar.
  #
  # rescue StandardError é deliberado e restrito a esta sondagem: os modos de
  # falha reais são vários e desinteressantes de enumerar (NoDatabaseError com o
  # banco apagado, ConnectionBad com o host fora, StatementInvalid com o schema
  # atrasado, e o que mais surgir), enquanto o que importa é sempre o mesmo —
  # registrar a classe e seguir para a próxima cidade. A classe do erro vai
  # junto justamente para que isto não vire um buraco onde bug some.
  def city_side_for(city)
    return { reachable: false, skipped: true, error: "status #{city.status}: sem banco para conectar" } if
      SKIPPED_STATUSES.include?(city.status)

    CityConnection.with(city) do
      profile = CityProfile.current

      {
        reachable: true,
        skipped: false,
        profile: profile && { name: profile.name, uf: profile.uf, ibge_code: profile.ibge_code },
        alert_recipients: AlertRecipient.active.map do |r|
          { channel: r.channel, destination: r.destination, escalation_order: r.escalation_order }
        end,
        consent_version: ConsentTerm.maximum(:version),
        active_protocols: ProtocolDefinition.active.order(:name).pluck(:name, :version).map { |n, v| "#{n} v#{v}" },
        counts: counts
      }
    end
  rescue StandardError => e
    # CitySchema.redact: a mensagem de uma PG::ConnectionBad traz a URL de
    # conexão inteira, COM a senha do role da cidade. Sem isto, a tela que
    # promete não mostrar segredo publicaria o segredo — e só no caminho de
    # erro, o menos exercitado e o mais fácil de não notar.
    { reachable: false, skipped: false, error: "#{e.class}: #{CitySchema.redact(e.message)}" }
  end

  # Contagem, nunca conteúdo: prova que a cidade tem movimento sem expor nada
  # de quem a usa.
  def counts
    {
      users: User.count,
      conversations: Conversation.count,
      triages: Triage.count,
      inbound_messages: InboundMessage.count,
      report_snapshots: ReportSnapshot.count
    }
  end
end
