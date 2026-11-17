class OrderMailer < ActionMailer::Base
  default from: "shop@example.com"

  def confirmation(order)
    @order = order
    mail(to: "buyer@example.com", subject: "Your order #{order.id}") do |format|
      format.text { render plain: "Thanks for order #{order.id}" }
    end
  end
end
