import { cn } from "@/lib/utils"

export function Card({ className, ...props }: any) {
  return <div className={cn("rounded-lg border", className)} {...props} />
}

export function CardTitle({ className, ...props }: any) {
  return <h3 className={cn("font-semibold", className)} {...props} />
}
