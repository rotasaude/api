# Endpoint único da API de manutenção (spec §8): POST, uma operação por
# requisição, sem lote. GET não existe — query em URL vai parar em log e cache.
module Maintenance
  class GraphqlController < BaseController
    # Dois limites, propósitos diferentes: o de QUERY bounds o que o parser vê
    # (profundidade, complexidade); o de BODY bounds o que o processo lê do
    # socket, ponto — o que inclui `variables`, que o cap de query sozinho não
    # alcança (uma query minúscula com um `variables` de megabytes passaria
    # ilesa pelo primeiro limite). O de body é checado primeiro e é mais largo
    # de propósito: ele é o teto absoluto da requisição inteira.
    MAX_QUERY_BYTES = 10_000
    MAX_BODY_BYTES = 64_000
    INTROSPECTION = /\b__(schema|type)\b/

    # Teto por IP: o mais LARGO dos dois, porque um IP pode ser um NAT com
    # vários mantenedores atrás. Ele é quem bounded o pior caso de quem NÃO
    # está autenticado — cada bearer recusado com o prefixo deste ambiente
    # escreve uma linha IMUTÁVEL em platform_events (o trigger recusa DELETE),
    # então "requisições por minuto" é literalmente "linhas por minuto".
    IP_RATE = 120
    # Teto por token (spec §7), o mais ESTREITO: se fosse o mais largo, o teto
    # por IP dispararia sempre primeiro e este nunca valeria nada. Um token de
    # automação que faz mais de uma chamada por segundo está em laço.
    TOKEN_RATE = 60
    RATE_WINDOW = 1.minute

    # `store:` de `rate_limit` é avaliado no CARREGAMENTO da classe: passar
    # `Rails.cache` direto congelaria o store daquele instante. Este delegador
    # resolve o cache a cada requisição — em development e staging é o mesmo
    # SolidCache de sempre, e é o que torna o teto EXERCITÁVEL por um spec (o
    # cache do ambiente de teste é :null_store, que nunca conta nada).
    module CacheStore
      def self.increment(...) = Rails.cache.increment(...)
    end

    TOO_MANY = -> { render json: { error: "too_many_requests" }, status: :too_many_requests }

    # C1: `prepend: true` porque este teto tem de rodar ANTES de
    # `resolve_maintenance_credential` — os before_action de
    # MaintainerAuthentication são declarados antes (em BaseController) e é lá
    # que um bearer recusado vira linha de auditoria. Um teto que só roda
    # depois da gravação não segura amplificação nenhuma.
    rate_limit to: IP_RATE, within: RATE_WINDOW, name: "ip", store: CacheStore, with: TOO_MANY, prepend: true

    # Spec §7 pede `rate_limit` POR TOKEN, que não existia. Roda depois da
    # resolução da credencial (é ela quem diz qual token é), e só quando há
    # token: sem o `if:`, toda sessão de navegador dividiria a mesma chave nula.
    rate_limit to: TOKEN_RATE, within: RATE_WINDOW, name: "token", store: CacheStore, with: TOO_MANY,
               by: -> { Current.maintenance_credential.token.id },
               if: -> { Current.maintenance_credential&.token? }

    def execute
      return head(:payload_too_large) if request.raw_post.bytesize > MAX_BODY_BYTES

      query = params[:query].to_s
      return head(:payload_too_large) if query.bytesize > MAX_QUERY_BYTES

      # Introspecção só em development: em ambiente publicado o schema é lido do
      # SDL em `contracts` (ADR-0015), não do endpoint. A checagem é aqui, e não
      # em Schema.disable_introspection_entry_points, porque aquela roda uma vez
      # no carregamento da classe — congelaria a decisão do ambiente que estava
      # ativo quando a classe carregou.
      if Rota.deployed? && query.match?(INTROSPECTION)
        return render(json: { errors: [ { message: "introspecção desligada em ambiente publicado" } ] }, status: :ok)
      end

      result = Schema.execute(
        query,
        variables: query_variables,
        operation_name: params[:operationName],
        context: {
          maintainer: current_maintainer,
          maintainer_session: Current.maintainer_session,
          credential: Current.maintenance_credential,
          request_id: request.request_id,
          # I5: o IP não estava no contexto, então nenhuma mutation conseguia
          # colocá-lo no payload de auditoria que a spec §9 descreve.
          ip: request.remote_ip
        }
      )

      audit_scope_refusal(result)

      render json: result
    end

    private

    # I1 (spec §9): "uso recusado de token … fora do escopo" não deixava rastro
    # nenhum — um token batendo em `auditEvents` ou tentando mutation era
    # recusado em silêncio, e é justamente o padrão que denuncia credencial
    # vazada. A gravação é AQUI, onde a recusa é observada e há requisição na
    # mão, e não nos analisadores, que rodam em toda query e devem continuar
    # sem efeito colateral.
    def audit_scope_refusal(result)
      credential = Current.maintenance_credential
      return unless credential&.token?

      fields = Analyzers::Refusal.refused_fields(result.to_h)
      return if fields.empty?

      MaintenanceAudit.record("maintenance.token.refused", outcome: "rejected", module_name: "token",
                              maintainer_id: credential.maintainer.id,
                              credential: credential.audit_payload,
                              refused_fields: fields, **audit_request_fields)
    end

    # Minor (fix round 2): `params[:variables]` cru não serve ao executor.
    # Cliente que manda `variables` como STRING JSON (é o que graphiql e vários
    # clientes fazem) levantava ArgumentError — 500 numa query legítima. E um
    # objeto aninhado chega como ActionController::Parameters, que só por sorte
    # se comporta como Hash na leitura: `to_unsafe_h` devolve o Hash de verdade,
    # em qualquer profundidade. Sem filtro de parâmetro, de propósito — quem
    # decide o que é aceitável aqui é o schema, campo a campo.
    def query_variables
      raw = params[:variables]

      case raw
      when ActionController::Parameters then raw.to_unsafe_h
      when String then raw.strip.empty? ? {} : JSON.parse(raw)
      when Hash then raw
      else {}
      end
    rescue JSON::ParserError
      {}
    end
  end
end
