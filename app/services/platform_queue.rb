# Onde um job pode ser enfileirado (spec banco-por-cidade §1/§4, Plano 5).
#
# A fila de cada cidade mora no banco dela; a fila de PLATAFORMA, no banco de
# plataforma, e só recebe jobs de ciclo de vida — o banco de plataforma nunca
# guarda dado de cidadão, e o payload de um job de cidade (telefone, mensagem) é
# dado de cidadão. Um job de cidade enfileirado fora da conexão de uma cidade
# cairia na fila de plataforma: aqui ele levanta em vez de cair. E um job de
# plataforma não entra na fila de uma cidade.
module PlatformQueue
  # Jobs e mailers de ciclo de vida. Job novo de plataforma entra aqui.
  JOBS = %w[ProvisionCityJob PurgePlatformAccessJob].freeze
  MAILERS = %w[InvitationMailer].freeze
  # Job do próprio Solid Queue para tarefas recorrentes do tipo command: cada
  # banco limpa a sua fila.
  ANYWHERE = %w[SolidQueue::RecurringJob].freeze

  class Misplaced < StandardError; end

  module_function

  # A fila de destino é a de plataforma quando o SolidQueue::Record está no shard
  # padrão E este processo não é o worker de uma cidade — no worker de cidade o
  # padrão foi trocado para o banco dela (CityWorkers::Child).
  def platform_target?
    SolidQueue::Record.current_shard == SolidQueue::Record.default_shard && CityWorkers::Context.city_slug.nil?
  end

  def check!(job)
    return if ANYWHERE.include?(job.class.name)

    if platform_target?
      raise Misplaced, "#{label(job)} é de cidade e não entra na fila de plataforma" unless platform?(job)
    elsif platform?(job)
      raise Misplaced, "#{label(job)} é de plataforma e não entra na fila de uma cidade"
    end
  end

  def platform?(job)
    return MAILERS.include?(label(job)) if job.is_a?(ActionMailer::MailDeliveryJob)

    JOBS.include?(job.class.name)
  end

  # Para entrega de e-mail, o nome do mailer (primeiro argumento do job).
  def label(job)
    job.is_a?(ActionMailer::MailDeliveryJob) ? job.arguments.first.to_s : job.class.name
  end
end
