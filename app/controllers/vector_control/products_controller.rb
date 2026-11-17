# /vector_control/products (módulo 35a, ADR 0054; contrato §4, §12; Q8, Q15):
# os produtos de campo, só a coordenação (403 missing_role). Lista `{ items }`
# com todos (ativos e inativos), por código; escritas devolvem o
# VectorProduct, sem envelope. Corpo só JSON (query na escrita → 422).
module VectorControl
  class ProductsController < BaseController
    before_action(only: %i[create update]) { query_only! }
    before_action :coordinator!

    def index
      return unless query_only!

      render json: { items: Json.products(VectorProduct.order(:code, :id).to_a) }
    end

    def create
      result = SaveProduct.call(params: body, by: Current.user)
      return render_failure(result) if result.failure?

      render json: Json.product(result.payload.fetch(:product)), status: :created
    end

    def update
      product = uuid?(params[:id]) ? VectorProduct.find_by(id: params[:id]) : nil
      return not_found unless product

      result = SaveProduct.call(params: body, by: Current.user, product: product)
      return render_failure(result) if result.failure?

      render json: Json.product(result.payload.fetch(:product))
    end
  end
end
