# Base de toda mutation que escreve dentro de uma cidade (spec da API §8, §9).
#
# O caminho é um só, nesta ordem:
#   1. escopo do token (Credential#allows_city?) — como em city(slug:);
#   2. tentativa gravada na plataforma (BaseMutation#audited) — se falhar, nada roda;
#   3. CityWriter abre a cidade e o bloco roda o command com o ator mantenedor e
#      o correlation_id, que o command grava no evento de domínio;
#   4. resultado: `ok`, `rejected` (regra de domínio, cidade inexistente ou não
#      ativa, step-up) ou `error` (qualquer exceção, inclusive conexão).
#
# A mensagem de uma exceção nunca sai: a resposta leva a classe (ou, para falha
# de conexão, a mensagem já redigida por CityWriter).
module Maintenance
  module Mutations
    class CityMutation < BaseMutation
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
      def in_city(city_slug:, event:, module_name:, rejection_path: "version", **fields)
        refuse_out_of_scope!(city_slug)

        audited(event: event, module_name: module_name, city_slug: city_slug, **fields) do |correlation_id|
          city = City.find_by(slug: city_slug)
          raise Rejected.new("cidade inexistente", path: "citySlug") if city.nil?

          begin
            result = CityWriter.call(city) { yield(MaintainerActor.new(credential.maintainer), correlation_id) }
          rescue CityWriter::NotWritable => e
            raise Rejected.new(e.message, path: "citySlug")
          end
          raise Rejected.new(result.message.presence || result.reason.to_s, path: rejection_path) if result.failure?

          result
        end
      rescue CityWriter::Unreachable => e
        raise GraphQL::ExecutionError.new(e.message, extensions: { "code" => "CITY_UNREACHABLE" })
      rescue GraphQL::ExecutionError
        raise
      rescue StandardError => e
        Rails.logger.warn("Maintenance::CityMutation: #{e.class} (mensagem omitida)")
        raise GraphQL::ExecutionError.new("falha ao escrever na cidade (#{e.class.name})",
                                          extensions: { "code" => "CITY_WRITE_FAILED" })
      end

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
