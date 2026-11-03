# Corpo comum de GET/POST/PATCH /transport/{vehicles,drivers,destinations}[/:id]
# (contrato §4): só a central (transport_dispatcher); listas `{ items: [...] }`
# com `?active=true`; registro de outro id → 404; recusas no formato uniforme.
# Cada controller diz a classe, o comando, a chave do resultado, a ordem e a
# forma JSON.
module Transport
  module FleetResource
    extend ActiveSupport::Concern

    included do
      before_action { forbid unless Access.dispatcher?(Current.user) }
    end

    def index
      scope = resource_class.all
      scope = scope.where(active: true) if params[:active] == "true"
      render json: { items: ordered(scope).map { |record| render_record(record) } }
    end

    def show
      record = find_record
      record ? render(json: render_record(record)) : not_found
    end

    def create
      result = command.call(attrs: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: render_record(result.payload.fetch(result_key)), status: :created
    end

    def update
      record = find_record
      return not_found unless record

      result = command.call(attrs: body, by: Current.user, record: record)
      return render_failure(result) if result.failure?

      render json: render_record(result.payload.fetch(result_key))
    end

    private

    def find_record = uuid?(params[:id]) ? resource_class.find_by(id: params[:id]) : nil
  end
end
