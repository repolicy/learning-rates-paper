


# Calculation functions ---------------------------------------------------


#' Calculation of the learning rate
#'
#' @param costs The technology costs. Usually yearly means 
#' @param cumulative_capacity  Cumulative capacity. Need to be same length as costs
#' @param digits Rounding precision
#'
#' @return Learning rate
#' 
calculate_learning_rate <- function(costs, cumulative_capacity, digits = params$default_digits){

  fit.lm.log <- lm(log(costs) ~ log(cumulative_capacity))  

  # Extract learning rate from coefficient b1
  # b1 = delta/r; r = assuming constant returns-to-scale parameter = 1. 
  # delta_L is the so-called learning-by-doing elasticity, indicating the percentage change in cost following a one percentage increase in cumulative capacity.
  delta_L <- coef(fit.lm.log)[2]
  delta_L_confint <- confint(fit.lm.log, "log(cumulative_capacity)")
  
  learning_rate <- 1 - 2 ^ delta_L # Percentage decrease in wind power cost for each doubling of cumulative capacity.
  confints <- 1 - 2 ^ delta_L_confint # Percentage decrease in wind power cost for each doubling of cumulative capacity.

  rsquared <- summary(fit.lm.log)$r.squared
  
  l <- list(
    learning_rate = round(learning_rate*100,digits),
    confint_lower = round(confints[2]*100, digits),
    confint_upper = round(confints[1]*100, digits),
    rsquared = round(rsquared,2),
    summary = summary(fit.lm.log)
  )
  
  return(l)
  
}

#' Converts results from calculate_learning_rate to list for further processing
#'
#' @param l 
#'
#' @return
#' @export
#'
#' @examples
to_results_list <- function(l, currency, interval_name){
  
  tibble(
    currency = currency,
    interval = interval_name,
    estimate = l$learning_rate,
    CI = str_glue("[{l$confint_lower};{l$confint_upper}]"),
    R2 =  l$rsquared
  )
  
}


#' Calculate_cummulative_sums
#' 
#' Calculates the deployment of capacity per year
#' @param projects_data A dataframe including the variable year and capacity
#'
calculate_cummulative_sums <- function(projects_data){
  projects_data %>% 
    group_by(year, subset_name) %>% 
    summarise(x_global = sum(capacity, na.rm = TRUE)) %>% 
    ungroup()
}

calculate_delta <- function(projects, x_global){
  
  # x$x = amount deployed with cost reported in currency i, measured in non-monetary terms (e.g., MW installed) in year t
  x <- projects %>%
    group_by(year, local_currency) %>% 
    summarise(x = sum(capacity)) %>% ungroup() %>% 
    complete(year, local_currency, fill = list(x = 0))
  
  # delta$delta = the share of deployment with cost reported in currency i in year t
  delta <- x %>%
    left_join(x_global, by = "year") %>% 
    mutate(delta = x / x_global) %>% 
    rename(currency = local_currency)
  
  # Check if assumption is met
  check <- aggregate(delta$delta, list(year = delta$year), sum)
  
  for(i_check in length(check)){
    if(check[i_check, "x"]!=1){
      print(warning("Sum of deltas is not 1!"))
    }
  }
  
  delta <- delta %>% 
    arrange(year) %>% 
    filter(year %in% all_years) %>% 
    left_join(currency_to_currency_area_translation)
  
  delta$currency <- factor(delta$currency, levels = c(relevant_currencies, "Other"))
  
  return(delta)
  
}


convert_to_real_costs <- function(average_global_costs_df, deflator, deflate = params$deflate){
  
  if(deflate){
    average_global_costs_df %>% 
      inner_join(deflator, by = c("currency", "year")) %>% 
      mutate(real_costs = nominal_costs / defl) %>% 
      select(year, currency, average_costs =  real_costs)
  
  } else {
    average_global_costs_df %>% 
      select(year, currency, average_costs = nominal_costs)
  }

  
}

calculate_P <- function(P_component){
  
  # calculate weighted average global cost converted to lead currency l in year t
  
  P_comp_sum <- P_component %>% 
    group_by(year, base_currency) %>% 
    summarise(P_nominal = sum(nominal_costs))
  
  select(P_comp_sum, year, currency = base_currency, nominal_costs = P_nominal)
  
}

get_exchange_rate_for_project <- function(exchange_rate_data, project_year, project_currency) {
  
  exchange_rate_data %>% 
    filter(year == project_year, currency == project_currency) %>% 
    pull(rate)
    
}


#' Exchange rate convertsion
#' 
#' Converts form exchange rates for a reference currency (e.g. USD), to the exchange rates between two other currencies
#'
#' @param exchange_rates a dataframe with exchange rates of a lead currency to other currencies 
#' @param other_currency_to_ref_currency_er name of the other currency (same as in dataframe) 
#' @param base_currency_to_ref_currency_er name of the lead currency (same as in dataframe) 
#'
#' @return
#' @export
#'
#' @examples
convert_exchange_rate <- function(exchange_rates_data, base_currency, other_currency){
  
  # the formula is c_other_curreny/c_base_currency = c_other_currency/USD * (c_base_currency/USD)^-1
  exchange_rates_data[other_currency] * as_tibble(exchange_rates_data[base_currency]^(-1))
  
  
}



# Plot functions -----------------------------------------------------------


#' Get comparison plot that compares two types of learning rates.
#' Depends on what's in the df.
#'
#' @param df 
#'
#' @return
#' @export
#'
#' @examples
get_comparison_plot <- function(df, corrected_rates){
  
  combined_plot_data <- df %>% 
    rename(lr = estimate) %>%  
    left_join(corrected_rates, by = c("interval")) %>% 
    mutate(
      lr = round(replace_na(lr, replace = 0),digits = 1),
      diff = round(lr - corrected_lr, digits = 1),
      diff_text = paste0(if_else(diff > 0, "+", ""), diff)) %>% 
    mutate(
      interval = fct_relevel(interval, names(intervals)),
      interval = fct_recode(interval,!!!plot_stips_label))
  
  
  plot_factors <- c("fx-corrected (USD)","",table_order_currency)
  
  plot_labels <- combined_plot_data %>% 
    expand(interval) %>% 
    add_column(label = letters[seq( from = 1, to = 3 )])
  
  plot <- combined_plot_data %>% 
    mutate(legend = factor(legend, plot_factors),
           legend = fct_relevel(legend, plot_factors)) %>% 
    
    ggplot(aes(fill = legend, y = lr, x = legend)) + 
    geom_bar(position="dodge", stat="identity") +
    geom_hline(aes(yintercept = corrected_lr)) + 
    geom_segment(. %>% filter(legend %in% relevant_currencies, diff > 0.1 | diff < -0.1 ), 
                 mapping=aes(x = legend, xend = legend, y = corrected_lr, yend=lr), 
                 arrow = arrow(length = unit(0.05, "inches"), type = "closed"), 
                 size = 1, color="black") +
    geom_text(. %>% filter(legend != ""), mapping = aes(y = lr/2, label = lr), col = "white", size = 3) + # learning rates
    geom_label_repel(. %>% filter(legend %in% relevant_currencies), mapping = aes(label = diff_text), nudge_y = 2, fill = "white", size = 3) + # differences
    
    geom_text(data = plot_labels, mapping = aes(x = 1, y = 40, label = label, fill = "USD"), fontface = "bold") +
    
    scale_fill_manual(values = c("fx-corrected (USD)" = "#000000", plot_colours_currencies)) +
    scale_y_continuous(limits = c(0,40), expand = expand_scale(mult = c(0, 0.1))) +
    scale_x_discrete(drop = FALSE) +
    labs(
      y = paste0("Learning rate in %")) +
    theme(
      axis.title.x = element_blank(),
      axis.text.x=element_blank(),
      axis.ticks.x=element_blank(), 
      panel.grid.major = element_blank(),
      legend.position="bottom") +
    guides(
      fill = guide_legend(nrow=1,byrow=TRUE)) +
    facet_grid( ~ interval)
  
  
  plot
  
}


#' Get normed plot
#' Produces the learning rate plots. In
#'
#' @param normed_plot_data Normed plot data, having the field year_for_text
#' @param intervals 
#'
#' @return
#' @export
#'
#' @examples
get_normed_plots <- function(normed_plot_data, intervals){
  
  plots <- list()
  
  for(i in seq_along(intervals)){
    interval <- intervals[[i]]
    interval_name <- names(intervals[i])
    interval_years <- as.numeric(interval[1]):as.numeric(interval[2])
    
    filtered_data <- normed_plot_data %>% 
      filter(year %in% interval_years)
    
    min_x <- min(filtered_data$cumulative_capacity)
    
    plots[[interval_name]] <- filtered_data %>% 
      ggplot(aes(cumulative_capacity/1000, normed_average_costs)) +
        geom_smooth(
          aes(col = currency),
          method="lm", formula = (y ~ x), se=FALSE) +
        geom_point(aes(col = currency)) +
        geom_text(aes(label = year_for_text), vjust = -0.6, hjust = 0.1, size = 3) +
        annotate("text", x = min_x/1000, y = 0, label = "Some text") +
        scale_x_continuous(trans="log", breaks = c(c(1,seq(2,10,2)) %o% 10^(0:4)), minor_breaks = 0.5) +
        scale_y_continuous(trans="log", breaks = c(seq(0,1,0.1), seq(1.2,2,0.2)), minor_breaks = NULL) +
        guides(
          linetype = guide_legend(title="Learning rate"), 
          col = guide_legend(title="Learning rate"), 
          size = guide_legend(title="Type")) +
        labs(x = "Cumulative capacity [GW]", 
             y = paste0("Index of costs per MW"),
             subtitle = interval_name) +
        scale_color_manual(values = plot_colours_currencies)
      
  }
  
  return(plots)
  
}

get_delta_plot <- function(delta_data, plot_type = "combined", legend = FALSE){
  
  delta_plot1 <- ggplot(data = delta_data, 
                        aes(x = year, y = x/1000, fill = currency_area)) +
    geom_bar(stat = "identity") +
    scale_x_continuous(breaks = seq(2004, 2017, 1), minor_breaks = NULL) +
    scale_fill_manual(values = plot_colours_country) +
    labs(x = "", 
         y = paste0("Added PV capacity [GW]")) +
    guides(fill = guide_legend(title = "Currency area")) + 
    theme(axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5 ))
  
  delta_plot2 <- ggplot(data = delta_data, 
                        aes(x = year, y = delta, fill = currency_area)) +
    geom_bar(position = "fill", stat="identity") +
    scale_x_continuous(breaks = seq(2004,2017,1), minor_breaks = NULL) +
    scale_fill_manual(values = plot_colours_country) +
    labs(x = "", 
         y = paste0("Share of added PV capacity")) +
    guides(fill=guide_legend(title="Currency area")) +
    theme(axis.text.x = element_text(angle = 90, hjust = 1,vjust = 0.5), 
          legend.position = if_else(legend, "right", "none"))
  
  
  delta_plot_legend <- get_legend(delta_plot1)
  delta_plot1_no_legend <- delta_plot1 + theme(legend.position="none")

  
  if (plot_type == "absolute"){
    return(delta_plot1)
  } else if(plot_type == "relative"){
    return(delta_plot2)
  } else {
    combined_plot <- grid.arrange(delta_plot1_no_legend, delta_plot2, delta_plot_legend, 
                                  ncol=3, widths=c(2.2, 2.2, 0.9))
  }
  
}


# ggplot objects can be passed in ..., or to plotlist (as a list of ggplot objects)
# - cols:   Number of columns in layout
# - layout: A matrix specifying the layout. If present, 'cols' is ignored.
#
# If the layout is something like matrix(c(1,2,3,3), nrow=2, byrow=TRUE),
# then plot 1 will go in the upper left, 2 will go in the upper right, and
# 3 will go all the way across the bottom.

multiplot <- function(..., plotlist=NULL, file, cols=1, layout=NULL) {
  library(grid)
  
  # Make a list from the ... arguments and plotlist
  plots <- c(list(...), plotlist)
  
  numPlots = length(plots)
  
  # If layout is NULL, then use 'cols' to determine layout
  if (is.null(layout)) {
    # Make the panel
    # ncol: Number of columns of plots
    # nrow: Number of rows needed, calculated from # of cols
    layout <- matrix(seq(1, cols * ceiling(numPlots/cols)),
                     ncol = cols, nrow = ceiling(numPlots/cols))
  }
  
  if (numPlots==1) {
    print(plots[[1]])
    
  } else {
    # Set up the page
    grid.newpage()
    pushViewport(viewport(layout = grid.layout(nrow(layout), ncol(layout))))
    
    # Make each plot, in the correct location
    for (i in 1:numPlots) {
      # Get the i,j matrix positions of the regions that contain this subplot
      matchidx <- as.data.frame(which(layout == i, arr.ind = TRUE))
      
      print(plots[[i]], vp = viewport(layout.pos.row = matchidx$row,
                                      layout.pos.col = matchidx$col))
    }
  }
}

get_legend<-function(myggplot){
  tmp <- ggplot_gtable(ggplot_build(myggplot))
  leg <- which(sapply(tmp$grobs, function(x) x$name) == "guide-box")
  legend <- tmp$grobs[[leg]]
  return(legend)
}

# Print and display functions ---------------------------------------------

print_number_table <- function(table, caption, digits = params$default_digits, ...){
  if(params$use_kable){
    kable(table, caption = caption, digits = digits, ...)
  } else {
    print(table)
  }
}

print_learning_rates_result <- function(df){
  
  nested_df <- df %>% 
    nest(-interval)
  
  for(i in 1:nrow(nested_df)){
    print(nested_df[[i, "interval"]])
    print_number_table(nested_df[[i, "data"]], nested_df[[i, "interval"]])
    
  }
  
}




# Helper functions --------------------------------------------------------

arrange_by_currencies <- function(table, currency_order){
  
  table %>% 
    mutate(currency = fct_relevel(currency, !!currency_order)) %>% 
    arrange(currency) 
  
}

make_interval_names <- function(intervals_list){
  
  n_intervals <- length(intervals_list)
  intervals_names <- character(n_intervals)
  
  for(i in 1:n_intervals){
    intervals_names[i] <- paste(paste(intervals_list[[i]][1],intervals_list[[i]][2],sep="-"))
  }
  
  return(intervals_names)
}


# Functions to convert the format of CPI and bloomberg

convert_year_to_date <- function(year){
  
  # take the middle day
  deflator_date <- as.Date(paste("02.07.", year),format = "%d.%m.%Y")
  return(deflator_date)
  
}

convert_location_to_currency <- function(location){
  
  location_currency_translation <- list(
    "USA" = "USD",
    "EA19" = "EUR",
    "GBR" = "GBP",
    "JPN" = "JPY",
    "CHN" = "CNY",
    "IND" = "INR")
  
  currency <- NA
  
  if(location %in% names(location_currency_translation)){
    currency <- location_currency_translation[[location]]
  }
  return(currency)
  
} 

#' Norm average cost
#' Used to produce the nomred plots
#'
#' @param costs_and_capacity dataframe including currency, average costs and capacity fields
norm_average_costs <- function(dcosts_and_capacity){
  

}


# Debug ------------------------------------------------------------------

write_debug_information <- function(data, title){
  

  if(params$debug){
    data <- as_tibble(data)
    
    directory <- paste0("output/debug/", params$base_currency, "/")
    filename <- paste0(title, ".csv")
    
    dir.create(directory)
    
    write_csv(data, paste0(directory,filename))
  }
  

}


