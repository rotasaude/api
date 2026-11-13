# As buscas de pessoa da visita e da atividade coletiva (módulo 24b, ADR 0052;
# contrato §5; Desvio 4/A-8; Q8), no padrão do Vaccination::PersonLookupsController
# e do DuplicatesController (27a/29), com a mesma resposta nos dois prefixos:
#   - POST …/people/lookup `{ cpf }` ou `{ cns }` (Patients::LookupByIdentifier)
#     → `{ patient_id, display_name, birth_date, sex, has_cpf, cns_masked }`;
#     ninguém → 404 person_not_found; par só declarado → 409 citizen_not_verified;
#     par validado sem paciente vira paciente; documento inválido → 422
#     invalid_cpf/invalid_cns; os dois ou nenhum → 422 invalid_request (com path);
#   - POST …/people/duplicates `{ full_name, birth_date, mother_name? }` →
#     `{ candidates: [{ patient_id, display_name, birth_date, sex, has_cpf, has_cns }] }`
#     (até 10, Patients::Duplicates).
# Tudo só do corpo (query → 422 invalid_request); trilha por pessoa mostrada
# (`person_trail`); 30 por minuto por usuário (429 too_many_requests), o
# orçamento único do HomeVisits::SearchBudget (Q67): as quatro buscas e as
# gravações que rodam a busca de duplicados ou a checagem de CPF/CNS;
# só quem registra no módulo (`person_registrar?`; senão 403 cbo_not_allowed).
# Quem inclui herda o portão do módulo e os helpers de recusa do BaseController.
module FieldPersonSearch
  extend ActiveSupport::Concern

  RATE = HomeVisits::SearchBudget::RATE

  # `store:` de `rate_limit` é avaliado no carregamento da classe; o delegador
  # resolve Rails.cache a cada requisição (o padrão da farmácia e da vacina).
  module RateLimitStore
    def self.increment(...) = Rails.cache.increment(...)
  end

  included do
    before_action :require_person_registrar!

    # Sem `name` e com o `scope` do orçamento: a chave é a do
    # HomeVisits::SearchBudget.cache_key (a mesma nas duas rotas e nos dois prefixos).
    rate_limit to: RATE, within: HomeVisits::SearchBudget::WINDOW, only: %i[lookup duplicates], scope: HomeVisits::SearchBudget::SCOPE,
               store: RateLimitStore, by: -> { Current.user&.id || request.remote_ip },
               with: -> { render json: { error: "too_many_requests" }, status: :too_many_requests }
  end

  def lookup
    return unless query_only!

    found = Patients::LookupByIdentifier.call(cpf: body_param("cpf"), cns: body_param("cns"))
    return render_failure(found) if found.failure?

    patient = found.payload.fetch(:patient)
    person_trail.person_viewed!(user: Current.user, patient_id: patient.id)
    render json: HomeVisits::People.person(patient)
  end

  def duplicates
    return unless query_only!

    full_name, birth_date, mother_name = %w[full_name birth_date mother_name].map { |key| body_param(key) }
    return render_refusal("invalid_request", path: "full_name") unless full_name.is_a?(String)
    return render_refusal("invalid_request", path: "birth_date") unless Patients::MatchKey.iso_date(birth_date)
    return render_refusal("invalid_request", path: "mother_name") unless mother_name.nil? || mother_name.is_a?(String)

    candidates = HomeVisits::People.duplicates(full_name: full_name, birth_date: birth_date, mother_name: mother_name)
    HomeVisits::People.candidates_viewed!(candidate_ids: candidates.map { |json| json[:patient_id] }, by: Current.user, trail: person_trail)
    render json: { candidates: candidates }
  end

  private

  def require_person_registrar!
    render_refusal("cbo_not_allowed") unless person_registrar?
  end
end
