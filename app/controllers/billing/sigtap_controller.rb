# GET /billing/sigtap/search (contrato §3): SIGTAP da competência (padrão: a
# do dia; a última ativa até ela), por início de código ou por nome, até 20.
# Profissional ou faturista. `q` não vai a log (filtro /\Aq\z/).
module Billing
  class SigtapController < BaseController
    LIMIT = 20
    INSTRUMENTS = { "02" => "bpa_i", "01" => "bpa_c" }.freeze

    def search
      return forbid unless Access.clerk?(Current.user) || Current.user.has_role?("health_professional")

      q = params[:q].is_a?(String) ? params[:q].strip : ""
      return render_error(:invalid_query) unless q.length.between?(2, 60)

      competence = params[:competence].presence || Time.zone.today.strftime("%Y%m")
      return invalid_filter unless competence.is_a?(String) && competence.match?(Periods::COMPETENCE)

      release = Terminology::Sigtap.release_for(competence)
      return render_error(:terminology_unavailable, :service_unavailable) unless release

      scope = SigtapProcedure.where(release_id: release.id)
      scope = q.match?(/\A\d+\z/) ? scope.where("code LIKE ?", "#{q}%") : scope.where("name ILIKE ?", "%#{SigtapProcedure.sanitize_sql_like(q)}%")
      rows = scope.order(:name, :code).limit(LIMIT).to_a
      render json: { procedures: rows.map { |row| item(row, release, rows) } }
    end

    private

    def item(row, release, rows)
      @instruments ||= SigtapProcedureInstrument.where(release_id: release.id, procedure_code: rows.map(&:code))
                                                .pluck(:procedure_code, :instrument_code).group_by(&:first)
      @with_cid ||= SigtapProcedureCid.where(release_id: release.id, procedure_code: rows.map(&:code)).distinct.pluck(:procedure_code).to_set
      instruments = Array(@instruments[row.code]).map { |_, code| INSTRUMENTS.fetch(code, "not_bpa") }.uniq.sort
      { code: row.code, name: row.name, instruments: instruments, requires_cid: @with_cid.include?(row.code), sex: row.sex,
        age_min_months: row.age_min_months, age_max_months: row.age_max_months }
    end
  end
end
