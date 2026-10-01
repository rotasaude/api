# Retenção do Solid Queue (api#31). Job terminado já sai de hora em hora
# (clear_solid_queue_finished, prazo padrão do gem de 1 dia). Job que FALHOU fica
# para inspeção, mas seus argumentos (telefone, e-mail) são dado pessoal: depois
# de FAILED_RETENTION descartamos a execução e a linha do job. Roda no banco da
# conexão corrente: o worker de cada cidade (fila da cidade) e o da plataforma.
class SolidQueueRetention
  FAILED_RETENTION = 30.days

  def self.discard_failed(...) = discard_failed_older_than(FAILED_RETENTION, ...)

  # Devolve quantos foram descartados. Só FailedExecution: job pronto, em
  # execução ou terminado não é tocado.
  def self.discard_failed_older_than(age)
    discarded = 0
    SolidQueue::FailedExecution.where("created_at < ?", age.ago).find_each do |execution|
      begin
        execution.discard
        discarded += 1
      rescue ActiveRecord::RecordNotFound
        # Reexecutada ou descartada em paralelo: já saiu, segue a varredura.
        next
      end
    end
    Rails.logger.info("[solid_queue_retention] failed_discarded=#{discarded}")
    discarded
  end
end
