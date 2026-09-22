# Base de toda mutation que escreve dentro de uma cidade (spec da API §8, §9).
#
# O caminho é um só, nesta ordem:
#   1. escopo do token (Credential#allows_city?) — como em city(slug:);
#   1b. o que vai para a auditoria é conferido: `city_slug` tem de ter a forma
#      de um slug de City, e todo campo auditado passado pela subclasse tem de
#      obedecer à regra dele em AUDITED_FIELD_RULES. Fora disso, erro de
#      usuário SEM linha de auditoria — platform_events é imutável e governado
#      pela Ruling R18, e não guarda texto livre do cliente;
#   2. tentativa gravada na plataforma (BaseMutation#audited) — se falhar, nada roda;
#   2b. a cidade existe e está ativa (sem conectar);
#   2c. step-up de TOTP, quando a mutation passa `step_up_code:` — AQUI, na
#      base, depois de a cidade ser conferida (código não é gasto numa cidade
#      que recusaria) e ANTES de abrir a conexão da cidade (falha de
#      plataforma no step-up não se confunde com cidade inalcançável, e o
#      command nunca roda sem ele);
#   3. CityWriter abre a cidade e o bloco roda o command com o ator mantenedor e
#      o correlation_id, que o command grava no evento de domínio;
#   4. resultado: `ok`, `rejected` (regra de domínio, cidade inexistente ou não
#      ativa, step-up) ou `error` (o command levantou, ou a cidade não abriu).
#      Sem resultado — o "desconhecido" da spec §9 — quando a conexão cai
#      DEPOIS de o command começar (pode ter comitado): o cliente recebe
#      CITY_UNREACHABLE dizendo isso, com o correlation id para conferir na
#      cidade. Uma falha ao GRAVAR o resultado também deixa a tentativa sem
#      resultado (BaseMutation#record_outcome) — o cliente recebe o resultado
#      real do command.
#
# A mensagem de uma exceção nunca sai: a resposta leva a classe (ou, para falha
# de conexão, a mensagem já redigida por CityWriter).
module Maintenance
  module Mutations
    class CityMutation < BaseMutation
      # Mesma regra de City (app/models/city.rb): sem ela, um slug de 60 KB
      # entraria em duas linhas imutáveis de auditoria por campo da operação.
      CITY_SLUG = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
      CITY_SLUG_LENGTH = 2..63

      # Nome de protocolo: o `pattern` de config/protocols/schema.json
      # (`^[a-z][a-z0-9-]+$`), com teto de tamanho; o domínio (Validator) só
      # exige String, então o teto é desta superfície.
      PROTOCOL_KEY = /\A[a-z][a-z0-9-]+\z/
      PROTOCOL_KEY_MAX = 63
      VERSION_RANGE = 1..10_000

      # O gancho para as subclasses: TODO campo que uma mutation passa a
      # `in_city` para a auditoria tem uma regra aqui — campo sem regra
      # levanta (erro de programação, não do cliente). Cada regra devolve a
      # mensagem de recusa, ou nil se o valor serve.
      AUDITED_FIELD_RULES = {
        protocol_key: lambda do |value|
          ok = value.is_a?(String) && value.length <= PROTOCOL_KEY_MAX && value.match?(PROTOCOL_KEY)
          "nome de protocolo inválido: minúsculas, dígitos e hífen, começando por letra, " \
            "até #{PROTOCOL_KEY_MAX} caracteres" unless ok
        end,
        version: lambda do |value|
          "versão inválida: inteiro de #{VERSION_RANGE.min} a #{VERSION_RANGE.max}" \
            unless value.is_a?(Integer) && VERSION_RANGE.cover?(value)
        end,
        # Nomes de campo escritos pelo CÓDIGO da mutation, nunca valores.
        changed_fields: lambda do |value|
          "changed_fields inválido" unless value.is_a?(Array) && value.all? { |f| f.is_a?(String) && f.match?(/\A[a-z_]{1,40}\z/) }
        end,
        # Decisão 4 (global-constraints.md): o TEXTO do motivo de reversão
        # nunca entra na auditoria de plataforma — só se um foi dado.
        reason_given: lambda do |value|
          "reason_given inválido" unless value == true || value == false
        end
      }.freeze

      # Caminho do erro de usuário por campo auditado; a subclasse sobrescreve
      # com `field_paths:` (saveProtocolDraft aponta os dois para `definition`).
      DEFAULT_FIELD_PATHS = { protocol_key: "name", version: "version" }.freeze

      argument :city_slug, String, required: true

      field :ok, Boolean, null: false
      field :errors, [ Types::UserErrorType ], null: false

      private

      # O bloco recebe (actor, correlation_id) e devolve o Result do command.
      # Result de falha vira Rejected no caminho `rejection_path`, com a
      # mensagem do próprio command — texto nosso, não do usuário.
      #
      # Ordem dos rescue (conferida no graphql-ruby 2.6): `audited` trata
      # Rejected (vira `{ ok: false, errors }` + `rejected`) e, para qualquer
      # outra exceção, grava `error` e RE-LEVANTA; só então os rescue daqui a
      # convertem em GraphQL::ExecutionError. O ExecutionError de
      # refuse_out_of_scope! sai antes de `audited` — recusa de escopo é
      # auditada pelo controller (Refusal::CODES), não aqui.
      #
      # `step_up_code:` (nil = sem step-up) é o TOTP das mutations que aprovam
      # ou põem em uso; elas nunca chamam step_up! por conta própria (guarda em
      # spec/graphql/maintenance/analyzers_spec.rb).
      #
      # `rejection_path` é o caminho da recusa do command: uma String, ou algo
      # que responde a `call(result)` quando o caminho depende do motivo.
      def in_city(city_slug:, event:, module_name:, rejection_path: "version", field_paths: {}, step_up_code: nil,
                  **fields)
        refuse_out_of_scope!(city_slug)
        refusal = unauditable_input(city_slug, fields, DEFAULT_FIELD_PATHS.merge(field_paths))
        return refusal if refusal

        correlation_id = nil
        audited(event: event, module_name: module_name, city_slug: city_slug, **fields) do |attempt_id|
          correlation_id = attempt_id
          city = City.find_by(slug: city_slug)
          raise Rejected.new("cidade inexistente", path: "citySlug") if city.nil?

          begin
            CityWriter.ensure_writable!(city)
            step_up!(step_up_code) unless step_up_code.nil?
            result = CityWriter.call(city) { yield(MaintainerActor.new(credential.maintainer), correlation_id) }
          rescue CityWriter::NotWritable => e
            raise Rejected.new(e.message, path: "citySlug")
          end
          if result.failure?
            path = rejection_path.respond_to?(:call) ? rejection_path.call(result) : rejection_path
            raise Rejected.new(result.message.presence || result.reason.to_s, path: path)
          end

          result
        end
      rescue CityWriter::Unreachable => e
        raise GraphQL::ExecutionError.new(unreachable_message(e, correlation_id), extensions: { "code" => "CITY_UNREACHABLE" })
      rescue GraphQL::ExecutionError
        raise
      rescue StandardError => e
        Rails.logger.warn("Maintenance::CityMutation: #{e.class} (mensagem omitida)")
        raise GraphQL::ExecutionError.new("falha ao escrever na cidade (#{e.class.name})",
                                          extensions: { "code" => "CITY_WRITE_FAILED" })
      end

      def outcome_unknown?(error) = error.is_a?(CityWriter::Unreachable) && error.started?

      # A mensagem de CityWriter::Unreachable já vem redigida. Se a conexão caiu
      # depois de o command começar, o cliente precisa saber que NÃO sabemos o
      # resultado — repetir às cegas pode escrever duas vezes.
      def unreachable_message(error, correlation_id)
        return error.message unless error.started?

        "resultado desconhecido: a conexão com a cidade caiu durante a escrita; confira na cidade " \
          "pelo correlation id #{correlation_id} antes de repetir (#{error.message})"
      end

      # O primeiro valor que não pode ir para a auditoria vira UM erro de
      # usuário (`{ ok: false, errors }`), sem gravar nada; nil se tudo serve.
      def unauditable_input(city_slug, fields, paths)
        unless city_slug.match?(CITY_SLUG) && CITY_SLUG_LENGTH.cover?(city_slug.length)
          return user_error("citySlug", "slug de cidade inválido")
        end

        fields.each do |name, value|
          rule = AUDITED_FIELD_RULES.fetch(name) do
            raise ArgumentError, "campo auditado sem regra em CityMutation::AUDITED_FIELD_RULES: #{name}"
          end
          message = rule.call(value)
          return user_error(paths.fetch(name, name.to_s), message) if message
        end

        nil
      end

      def user_error(path, message) = { ok: false, errors: [ { path: path, message: message } ] }

      # Mesma recusa, com a mesma etiqueta, de QueryType#city — e pelo mesmo
      # motivo o controller a audita uma vez (Refusal::CODES). `field` é o
      # GraphQL::Schema::Field do campo de raiz (Resolver#field); graphql_name
      # é o nome camelCase publicado (`saveProtocolDraft`), mesmo sob alias.
      def refuse_out_of_scope!(city_slug)
        return if credential.allows_city?(city_slug)

        raise GraphQL::ExecutionError.new(
          "cidade fora do escopo do token",
          extensions: { "code" => Analyzers::Refusal::CITY_OUT_OF_SCOPE,
                        Analyzers::Refusal::FIELDS => [ field.graphql_name ] }
        )
      end
    end
  end
end
