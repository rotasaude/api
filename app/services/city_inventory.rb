# Levantamento de configuração de todas as cidades registradas, para a tela de
# manutenção de development (GET /maintenance, dev-only).
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

  # O console é da PLATAFORMA e não tem vínculo com cidade nenhuma: Operator
  # vive no banco de plataforma e não tem membership. Por isso sai POR FORA do
  # inventário por cidade — repetir a mesma lista dentro de cada seção
  # sugeriria um vínculo que não existe.
  #
  # mfa_required é fixo em true porque Operators::SessionsController EXIGE
  # TOTP, ao contrário do login da cidade, onde MFA é por conta. Sem isso na
  # tela, quem tentar entrar só com e-mail e senha conclui que a conta quebrou.
  def console
    {
      url: ENV.fetch("ALLOWED_ORIGINS", "http://admin.localhost:5174").split(",").first.to_s.strip + "/admin/",
      mfa_required: true,
      operators: Operator.order(:email_address).map do |o|
        { email: o.email_address, active: o.active?, mfa: o.mfa_enrolled? }
      end
    }
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
      urls: urls_for(city),
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

  # Onde cada frontend da cidade atende. Sai do catálogo, sem abrir conexão.
  #
  # dashboard e wpda NÃO compartilham porta em dev: em produção um host só
  # resolve os dois caminhos, mas aqui cada app Vite tem a sua, e é por isso que
  # CityPublicUrl tem uma env var separada para o wpda. Esse é justamente o
  # detalhe que ninguém lembra de cabeça — é o principal motivo destas URLs
  # estarem na tela.
  def urls_for(city)
    {
      dashboard: "#{CityPublicUrl.base_for_slug(city.slug)}/dashboard/",
      wpda: "#{CityPublicUrl.wpda_base_for_slug(city.slug)}/wpda/",
      impersonate: impersonate_url_for(city.slug)
    }
  end

  # O link de impersonate sai no HOST DA CIDADE e na porta da API — as duas
  # coisas são obrigatórias e por motivos diferentes.
  #
  # Host da cidade porque o cookie de sessão é host-only (write_session_cookie
  # nunca seta `domain:`): gravado em `localhost`, onde esta tela vive, ele não
  # seria enviado para `curitiba.localhost`. Porta da API porque é o Rails que
  # grava o cookie — e cookie IGNORA porta, então o que ele grava em :3030 vale
  # no dashboard em :5175. É essa assimetria que faz o atalho funcionar sem
  # tocar em nenhum frontend.
  #
  # O host vem do mesmo template público das cidades, que é a fonte autoritativa
  # de qual host resolve para qual cidade (CityCatalog lê o primeiro rótulo).
  def impersonate_url_for(slug)
    uri = URI.parse(CityPublicUrl.base_for_slug(slug))
    uri.port = ENV.fetch("PUBLIC_PORT", "3000").to_i
    "#{uri}/dev/impersonate"
  end

  # Quem entra NESTA cidade e com que papel. `roles` vem só de membership ativa
  # (revogar é end-date, não DELETE): conta que perdeu o papel aparece com a
  # lista vazia, em vez de sumir — ela ainda existe e ainda autentica.
  #
  # Senha e otp_secret ficam de fora por regra, não por esquecimento: otp_secret
  # é `encrypts`, mesma classe do access_token já excluído, e digest de senha
  # numa página é material de ataque offline, não diagnóstico. O que serve para
  # acessar é saber SE a conta exige MFA — o segredo em si mora nas seeds.
  def accounts_for
    User.order(:email_address).map do |user|
      {
        email: user.email_address,
        roles: user.memberships.active.order(:role).pluck(:role),
        active: user.active?,
        mfa: user.mfa_enrolled?
      }
    end
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
        accounts: accounts_for,
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
