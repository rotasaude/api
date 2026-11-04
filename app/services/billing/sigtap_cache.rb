# Leituras da SIGTAP memorizadas DENTRO de uma chamada (revisão final do
# módulo 22, I2): fechamento, pendências e resumo criticam N procedimentos
# sob trava e repetiriam as mesmas consultas por código. Um objeto por
# chamada, passado ao Billing::Critic; nunca estado global ou de processo
# (a SIGTAP ativa muda por importação e a cidade muda por requisição).
module Billing
  class SigtapCache
    def initialize
      @releases = {}
      @rows = {}
    end

    # Release da competência (ou a última ativa anterior), como Terminology::Sigtap.release_for.
    def release(competence)
      @releases.fetch(competence) { @releases[competence] = Terminology::Sigtap.release_for(competence) }
    end

    def procedure(release, code) = memo(:procedure, release, code) { SigtapProcedure.find_by(release_id: release.id, code: code) }
    # Módulo 31: quantidade máxima e permanência do procedimento (nulo = sem limite, ou release anterior ao módulo).
    def max_quantity(release, code) = procedure(release, code)&.max_quantity
    def max_stay_days(release, code) = procedure(release, code)&.max_stay_days
    def attributes(release, code) = memo(:attributes, release, code) { scope(SigtapProcedureAttribute, release, code).pluck(:attribute_code).to_set }
    def instruments(release, code) = memo(:instruments, release, code) { scope(SigtapProcedureInstrument, release, code).pluck(:instrument_code) }
    def cbos(release, code) = memo(:cbos, release, code) { scope(SigtapProcedureCbo, release, code).pluck(:cbo_code).to_set }
    def cids(release, code) = memo(:cids, release, code) { scope(SigtapProcedureCid, release, code).pluck(:cid_code).to_set }

    def inspect = "#<#{self.class.name} releases=#{@releases.size} rows=#{@rows.size}>"

    private

    def memo(kind, release, code)
      key = [ kind, release.id, code ]
      @rows.fetch(key) { @rows[key] = yield }
    end

    def scope(model, release, code) = model.where(release_id: release.id, procedure_code: code)
  end
end
