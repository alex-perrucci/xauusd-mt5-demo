#property strict
#property version   "3.00"
#property description "XAUUSD demo-only H1 multi-trade bridge with ticketed hedging support"

#define SIGNAL_FILE        "xauusd\\signal.txt"
#define GUARD_FILE         "xauusd\\guard.txt"
#define ACK_FILE           "xauusd\\ack.txt"
#define STATE_FILE         "xauusd\\state.txt"
#define LAST_SIGNAL_FILE   "xauusd\\last_signal.txt"
#define PENDING_META_FILE  "xauusd\\pending_meta.txt"

#define ABS_MAX_RISK_PCT   0.5
#define ABS_MAX_VOLUME     0.01
#define ABS_MIN_RR         2.0
#define ABS_MAX_EXPOSURES  3

struct GuardConfig
  {
   long   expected_login;
   string expected_server;
   string broker_symbol;
   double max_spread_points;
   double max_risk_pct;
   double min_rr;
   ulong  magic;
   ulong  deviation_points;
  };

struct BridgeSignal
  {
   int      schema;
   string   id;
   string   action;
   string   logical_symbol;
   bool     has_entry;
   double   entry;
   bool     has_sl;
   double   sl;
   bool     has_tp;
   double   tp;
   double   risk_pct;
   ulong    target_ticket;
   long     created_epoch;
   long     valid_epoch;
  };

string g_last_signal_id="";

int OnInit()
  {
   g_last_signal_id=ReadSmallFile(LAST_SIGNAL_FILE);
   EventSetTimer(1);
   Print("SignalBridge v3 initialized. Data path=",TerminalInfoString(TERMINAL_DATA_PATH));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   CancelExpiredPending();
   WriteState();
   ProcessBridge();
  }

string SafeField(string value)
  {
   StringReplace(value,"|","/");
   StringReplace(value,"\r"," ");
   StringReplace(value,"\n"," ");
   return value;
  }

string ReadSmallFile(const string file_name)
  {
   int h=FileOpen(file_name,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return "";
   string value=FileReadString(h);
   FileClose(h);
   return value;
  }

bool WriteSmallFile(const string file_name,const string value)
  {
   int h=FileOpen(file_name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return false;
   FileWriteString(h,value+"\r\n");
   FileFlush(h);
   FileClose(h);
   return true;
  }

bool AppendSmallFile(const string file_name,const string value)
  {
   int h=FileOpen(file_name,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      h=FileOpen(file_name,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return false;
   FileSeek(h,0,SEEK_END);
   FileWriteString(h,value+"\r\n");
   FileFlush(h);
   FileClose(h);
   return true;
  }

void ClearSmallFile(const string file_name)
  {
   WriteSmallFile(file_name,"");
  }

long BrokerUtcOffsetSeconds()
  {
   return (long)TimeCurrent()-(long)TimeGMT();
  }

datetime UtcEpochToBrokerTime(const long utc_epoch)
  {
   return (datetime)(utc_epoch+BrokerUtcOffsetSeconds());
  }

long BrokerTimeToUtcEpoch(const datetime broker_time)
  {
   return (long)broker_time-BrokerUtcOffsetSeconds();
  }

void Acknowledge(const string id,const string status,const string message)
  {
   string line=id+"|"+status+"|"+IntegerToString((int)TimeGMT())+"|"+SafeField(message);
   WriteSmallFile(ACK_FILE,line);
  }

void FinishSignal(const string id,const string status,const string message)
  {
   g_last_signal_id=id;
   WriteSmallFile(LAST_SIGNAL_FILE,id);
   Acknowledge(id,status,message);
   Print("signal ",id," -> ",status,": ",message);
  }

bool LoadGuard(GuardConfig &guard,string &error)
  {
   string line=ReadSmallFile(GUARD_FILE);
   if(line=="")
     {
      error="guard file missing or empty";
      return false;
     }

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   int count=StringSplit(line,delimiter,f);
   if(count!=9 || f[0]!="1")
     {
      error="invalid guard format";
      return false;
     }

   guard.expected_login=(long)StringToInteger(f[1]);
   guard.expected_server=f[2];
   guard.broker_symbol=f[3];
   guard.max_spread_points=StringToDouble(f[4]);
   guard.max_risk_pct=MathMin(StringToDouble(f[5]),ABS_MAX_RISK_PCT);
   guard.min_rr=MathMax(StringToDouble(f[6]),ABS_MIN_RR);
   guard.magic=(ulong)StringToInteger(f[7]);
   guard.deviation_points=(ulong)StringToInteger(f[8]);

   if(guard.expected_login<=0 || guard.expected_server=="" || guard.broker_symbol=="")
     {
      error="guard account/server/symbol is incomplete";
      return false;
     }
   if(guard.max_spread_points<=0 || guard.max_risk_pct<=0 || guard.magic==0)
     {
      error="guard risk/spread/magic is invalid";
      return false;
     }
   return true;
  }

bool LoadSignal(BridgeSignal &signal,string &error)
  {
   string line=ReadSmallFile(SIGNAL_FILE);
   if(line=="")
      return false;

   string f[];
   ushort delimiter=StringGetCharacter("|",0);
   int count=StringSplit(line,delimiter,f);
   if(count!=11)
     {
      error="invalid signal field count";
      return false;
     }

   signal.schema=(int)StringToInteger(f[0]);
   signal.id=f[1];
   signal.action=f[2];
   signal.logical_symbol=f[3];
   signal.has_entry=(f[4]!="");
   signal.entry=signal.has_entry ? StringToDouble(f[4]) : 0.0;
   signal.has_sl=(f[5]!="");
   signal.sl=signal.has_sl ? StringToDouble(f[5]) : 0.0;
   signal.has_tp=(f[6]!="");
   signal.tp=signal.has_tp ? StringToDouble(f[6]) : 0.0;
   signal.risk_pct=StringToDouble(f[7]);
   signal.target_ticket=(f[8]!="") ? (ulong)StringToInteger(f[8]) : 0;
   signal.created_epoch=(long)StringToInteger(f[9]);
   signal.valid_epoch=(long)StringToInteger(f[10]);

   if(signal.schema!=3 || signal.id=="" || signal.logical_symbol!="XAUUSD")
     {
      error="invalid schema/id/logical symbol";
      return false;
     }
   return true;
  }

bool IsKnownAction(const string action)
  {
   return action=="NO_TRADE" || action=="HOLD" || action=="STATUS" ||
          action=="BUY" || action=="SELL" ||
          action=="BUY_STOP" || action=="SELL_STOP" ||
          action=="CLOSE" || action=="CANCEL" || action=="MODIFY" ||
          action=="CLOSE_ALL" || action=="CANCEL_ALL";
  }

bool CheckAccountGuard(const GuardConfig &guard,string &error)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      error="terminal not connected";
      return false;
     }
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)!=ACCOUNT_TRADE_MODE_DEMO)
     {
      error="account is not DEMO";
      return false;
     }
   if((long)AccountInfoInteger(ACCOUNT_LOGIN)!=guard.expected_login)
     {
      error="unexpected account login";
      return false;
     }
   if(AccountInfoString(ACCOUNT_SERVER)!=guard.expected_server)
     {
      error="unexpected account server";
      return false;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      error="automated trading is disabled";
      return false;
     }
   return true;
  }

bool IsHedgingAccount()
  {
   return (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING;
  }

int VolumeDigits(const double step)
  {
   int digits=0;
   double scaled=step;
   while(digits<8 && MathAbs(scaled-MathRound(scaled))>1e-9)
     {
      scaled*=10.0;
      digits++;
     }
   return digits;
  }

double NormalizeRiskVolume(const string symbol,const ENUM_ORDER_TYPE side_type,
                           const double entry,const double sl,const double risk_pct,string &error)
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount=equity*(risk_pct/100.0);
   if(equity<=0 || risk_amount<=0)
     {
      error="invalid equity/risk amount";
      return 0.0;
     }

   double one_lot_profit=0.0;
   if(!OrderCalcProfit(side_type,symbol,1.0,entry,sl,one_lot_profit))
     {
      error="OrderCalcProfit failed";
      return 0.0;
     }
   double one_lot_loss=MathAbs(one_lot_profit);
   if(one_lot_loss<=0)
     {
      error="one-lot SL loss is zero";
      return 0.0;
     }

   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double broker_vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   double vmax=MathMin(broker_vmax,ABS_MAX_VOLUME);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(vmin<=0 || broker_vmax<=0 || step<=0)
     {
      error="invalid broker volume constraints";
      return 0.0;
     }
   if(vmin>ABS_MAX_VOLUME)
     {
      error="broker minimum volume exceeds hard safety cap";
      return 0.0;
     }

   double raw=risk_amount/one_lot_loss;
   if(raw<vmin)
     {
      error="required volume below broker minimum; refusing to exceed risk cap";
      return 0.0;
     }

   double volume=MathFloor((MathMin(raw,vmax)+1e-12)/step)*step;
   volume=NormalizeDouble(volume,VolumeDigits(step));

   double actual_profit=0.0;
   if(volume<=0 || !OrderCalcProfit(side_type,symbol,volume,entry,sl,actual_profit))
     {
      error="volume risk verification failed";
      return 0.0;
     }
   if(MathAbs(actual_profit)>risk_amount*1.01)
     {
      error="normalized volume exceeds requested risk";
      return 0.0;
     }
   return volume;
  }

ENUM_ORDER_TYPE_FILLING FillingMode(const string symbol)
  {
   long filling=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   long execution=SymbolInfoInteger(symbol,SYMBOL_TRADE_EXEMODE);
   if((filling & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if(execution!=SYMBOL_TRADE_EXECUTION_MARKET)
      return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
  }

bool IsManagedPosition(const string symbol,const ulong magic)
  {
   return PositionGetString(POSITION_SYMBOL)==symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==magic;
  }

bool IsManagedOrder(const string symbol,const ulong magic)
  {
   return OrderGetString(ORDER_SYMBOL)==symbol &&
          (ulong)OrderGetInteger(ORDER_MAGIC)==magic;
  }

int ManagedPositionCount(const string symbol,const ulong magic)
  {
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && IsManagedPosition(symbol,magic))
         count++;
     }
   return count;
  }

int ManagedOrderCount(const string symbol,const ulong magic)
  {
   int count=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket>0 && IsManagedOrder(symbol,magic))
         count++;
     }
   return count;
  }

int UnmanagedSymbolExposureCount(const string symbol,const ulong magic)
  {
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=magic)
         count++;
     }
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || OrderGetString(ORDER_SYMBOL)!=symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC)!=magic)
         count++;
     }
   return count;
  }

ENUM_ORDER_TYPE DirectionForOrderType(const ENUM_ORDER_TYPE type)
  {
   if(type==ORDER_TYPE_BUY || type==ORDER_TYPE_BUY_LIMIT ||
      type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT)
      return ORDER_TYPE_BUY;
   return ORDER_TYPE_SELL;
  }

double RiskAmountForTrade(const string symbol,const ENUM_ORDER_TYPE direction,
                          const double volume,const double entry,const double sl)
  {
   if(volume<=0 || entry<=0 || sl<=0)
      return DBL_MAX;
   double profit=0.0;
   if(!OrderCalcProfit(direction,symbol,volume,entry,sl,profit))
      return DBL_MAX;
   if(profit>=0)
      return 0.0;
   return -profit;
  }

double ManagedRiskAmount(const GuardConfig &guard,const ulong exclude_ticket=0)
  {
   string symbol=guard.broker_symbol;
   double total=0.0;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || ticket==exclude_ticket || !IsManagedPosition(symbol,guard.magic))
         continue;
      ENUM_ORDER_TYPE direction=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
                                ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double amount=RiskAmountForTrade(symbol,direction,
                                       PositionGetDouble(POSITION_VOLUME),
                                       PositionGetDouble(POSITION_PRICE_OPEN),
                                       PositionGetDouble(POSITION_SL));
      if(amount==DBL_MAX)
         return DBL_MAX;
      total+=amount;
     }

   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || ticket==exclude_ticket || !IsManagedOrder(symbol,guard.magic))
         continue;
      ENUM_ORDER_TYPE direction=DirectionForOrderType((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE));
      double amount=RiskAmountForTrade(symbol,direction,
                                       OrderGetDouble(ORDER_VOLUME_CURRENT),
                                       OrderGetDouble(ORDER_PRICE_OPEN),
                                       OrderGetDouble(ORDER_SL));
      if(amount==DBL_MAX)
         return DBL_MAX;
      total+=amount;
     }
   return total;
  }

double ManagedRiskPct(const GuardConfig &guard)
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double amount=ManagedRiskAmount(guard,0);
   if(equity<=0 || amount==DBL_MAX)
      return 999.0;
   return 100.0*amount/equity;
  }

bool CheckAggregateRisk(const GuardConfig &guard,const double candidate_amount,
                        const ulong exclude_ticket,string &message)
  {
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity<=0 || candidate_amount<0 || candidate_amount==DBL_MAX)
     {
      message="invalid aggregate risk inputs";
      return false;
     }
   double current=ManagedRiskAmount(guard,exclude_ticket);
   if(current==DBL_MAX)
     {
      message="existing managed exposure has no valid SL/risk";
      return false;
     }
   double pct=100.0*(current+candidate_amount)/equity;
   if(pct>ABS_MAX_RISK_PCT+1e-8)
     {
      message="aggregate managed risk cap exceeded: "+DoubleToString(pct,3)+"%";
      return false;
     }
   return true;
  }

bool CanAddExposure(const GuardConfig &guard,string &message)
  {
   if(!IsHedgingAccount())
     {
      message="account is not hedging";
      return false;
     }
   if(UnmanagedSymbolExposureCount(guard.broker_symbol,guard.magic)>0)
     {
      message="unmanaged XAUUSD exposure present";
      return false;
     }
   int exposures=ManagedPositionCount(guard.broker_symbol,guard.magic)+
                 ManagedOrderCount(guard.broker_symbol,guard.magic);
   if(exposures>=ABS_MAX_EXPOSURES)
     {
      message="maximum managed exposures reached";
      return false;
     }
   return true;
  }

bool SendChecked(MqlTradeRequest &request,MqlTradeResult &result,string &message)
  {
   MqlTradeCheckResult check={};
   ResetLastError();
   if(!OrderCheck(request,check))
     {
      message="OrderCheck failed: "+check.comment+" err="+IntegerToString(GetLastError());
      return false;
     }

   ResetLastError();
   if(!OrderSend(request,result))
     {
      message="OrderSend failed: err="+IntegerToString(GetLastError());
      return false;
     }

   if(result.retcode!=TRADE_RETCODE_DONE &&
      result.retcode!=TRADE_RETCODE_PLACED &&
      result.retcode!=TRADE_RETCODE_DONE_PARTIAL)
     {
      message="trade rejected retcode="+IntegerToString((int)result.retcode)+" "+result.comment;
      return false;
     }
   message="retcode="+IntegerToString((int)result.retcode)+
           " deal="+(string)result.deal+" order="+(string)result.order;
   return true;
  }

bool ValidateGeometry(const bool is_buy,const double entry,const double sl,
                      const double tp,const double min_rr,double &rr,string &message)
  {
   double risk_distance=is_buy ? entry-sl : sl-entry;
   double reward_distance=is_buy ? tp-entry : entry-tp;
   if(risk_distance<=0 || reward_distance<=0)
     {
      message="invalid SL/entry/TP geometry";
      return false;
     }
   rr=reward_distance/risk_distance;
   if(rr<min_rr || rr<ABS_MIN_RR)
     {
      message="RR below minimum: "+DoubleToString(rr,2);
      return false;
     }
   return true;
  }

bool CheckSpread(const string symbol,MqlTick &tick,string &message,const GuardConfig &guard)
  {
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
     {
      message="no live tick";
      return false;
     }
   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   if(point<=0)
     {
      message="invalid point size";
      return false;
     }
   double spread=(tick.ask-tick.bid)/point;
   if(spread>guard.max_spread_points)
     {
      message="spread too high: "+DoubleToString(spread,1);
      return false;
     }
   return true;
  }

bool ValidateRequestedRisk(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   if(signal.risk_pct<=0 ||
      signal.risk_pct>guard.max_risk_pct ||
      signal.risk_pct>ABS_MAX_RISK_PCT)
     {
      message="risk exceeds local cap";
      return false;
     }
   return true;
  }

bool OpenMarket(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   if(!SymbolSelect(symbol,true))
     {
      message="broker symbol unavailable";
      return false;
     }
   if(!CanAddExposure(guard,message) || !ValidateRequestedRisk(signal,guard,message))
      return false;
   if(!signal.has_sl || !signal.has_tp || signal.sl<=0 || signal.tp<=0)
     {
      message="SL and TP are mandatory";
      return false;
     }

   MqlTick tick={};
   if(!CheckSpread(symbol,tick,message,guard))
      return false;

   bool is_buy=(signal.action=="BUY");
   ENUM_ORDER_TYPE type=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double entry=is_buy ? tick.ask : tick.bid;
   double rr=0.0;
   if(!ValidateGeometry(is_buy,entry,signal.sl,signal.tp,guard.min_rr,rr,message))
      return false;

   string error="";
   double volume=NormalizeRiskVolume(symbol,type,entry,signal.sl,signal.risk_pct,error);
   if(volume<=0)
     {
      message=error;
      return false;
     }

   double candidate=RiskAmountForTrade(symbol,type,volume,entry,signal.sl);
   if(!CheckAggregateRisk(guard,candidate,0,message))
      return false;

   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL;
   request.symbol=symbol;
   request.volume=volume;
   request.type=type;
   request.price=NormalizeDouble(entry,digits);
   request.sl=NormalizeDouble(signal.sl,digits);
   request.tp=NormalizeDouble(signal.tp,digits);
   request.deviation=guard.deviation_points;
   request.magic=guard.magic;
   request.comment="cgpt-h1:"+StringSubstr(signal.id,0,14);
   request.type_time=ORDER_TIME_GTC;
   request.type_filling=FillingMode(symbol);

   return SendChecked(request,result,message);
  }

void AddPendingMeta(const ulong ticket,const long valid_epoch)
  {
   if(ticket>0 && valid_epoch>0)
      AppendSmallFile(PENDING_META_FILE,(string)ticket+"|"+(string)valid_epoch);
  }

bool PlacePending(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   if(!SymbolSelect(symbol,true))
     {
      message="broker symbol unavailable";
      return false;
     }
   if(!CanAddExposure(guard,message) || !ValidateRequestedRisk(signal,guard,message))
      return false;
   if(!signal.has_entry || !signal.has_sl || !signal.has_tp ||
      signal.entry<=0 || signal.sl<=0 || signal.tp<=0)
     {
      message="entry, SL and TP are mandatory for pending orders";
      return false;
     }

   MqlTick tick={};
   if(!CheckSpread(symbol,tick,message,guard))
      return false;

   bool is_buy=(signal.action=="BUY_STOP");
   if(is_buy && signal.entry<=tick.ask)
     {
      message="BUY_STOP entry must be above current ask";
      return false;
     }
   if(!is_buy && signal.entry>=tick.bid)
     {
      message="SELL_STOP entry must be below current bid";
      return false;
     }

   double rr=0.0;
   if(!ValidateGeometry(is_buy,signal.entry,signal.sl,signal.tp,guard.min_rr,rr,message))
      return false;

   ENUM_ORDER_TYPE direction=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string error="";
   double volume=NormalizeRiskVolume(symbol,direction,signal.entry,signal.sl,signal.risk_pct,error);
   if(volume<=0)
     {
      message=error;
      return false;
     }

   double candidate=RiskAmountForTrade(symbol,direction,volume,signal.entry,signal.sl);
   if(!CheckAggregateRisk(guard,candidate,0,message))
      return false;

   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_PENDING;
   request.symbol=symbol;
   request.volume=volume;
   request.type=is_buy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   request.price=NormalizeDouble(signal.entry,digits);
   request.sl=NormalizeDouble(signal.sl,digits);
   request.tp=NormalizeDouble(signal.tp,digits);
   request.magic=guard.magic;
   request.comment="cgpt-h1:"+StringSubstr(signal.id,0,14);
   request.type_filling=ORDER_FILLING_RETURN;

   long expiration_modes=SymbolInfoInteger(symbol,SYMBOL_EXPIRATION_MODE);
   if((expiration_modes & SYMBOL_EXPIRATION_SPECIFIED)==SYMBOL_EXPIRATION_SPECIFIED)
     {
      request.type_time=ORDER_TIME_SPECIFIED;
      request.expiration=UtcEpochToBrokerTime(signal.valid_epoch);
     }
   else
     {
      request.type_time=ORDER_TIME_GTC;
     }

   bool ok=SendChecked(request,result,message);
   if(ok && result.order>0 && request.type_time==ORDER_TIME_GTC)
      AddPendingMeta(result.order,signal.valid_epoch);
   return ok;
  }

bool CancelManagedTicket(const ulong ticket,const GuardConfig &guard,string &message)
  {
   if(ticket==0 || !OrderSelect(ticket))
     {
      message="target pending order not found";
      return false;
     }
   if(!IsManagedOrder(guard.broker_symbol,guard.magic))
     {
      message="target order is not managed by this bridge";
      return false;
     }

   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_REMOVE;
   request.order=ticket;
   request.magic=guard.magic;
   return SendChecked(request,result,message);
  }

bool CancelAllManaged(const GuardConfig &guard,string &message)
  {
   bool found=false;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(guard.broker_symbol,guard.magic))
         continue;
      found=true;
      string one="";
      if(!CancelManagedTicket(ticket,guard,one))
        {
         message=one;
         return false;
        }
     }
   message=found ? "all managed pending orders cancelled" : "no managed pending orders";
   return true;
  }

void CancelExpiredPending()
  {
   int h=FileOpen(PENDING_META_FILE,FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE)
      return;

   GuardConfig guard={};
   string error="";
   bool guard_ok=LoadGuard(guard,error) && CheckAccountGuard(guard,error);
   string keep="";

   while(!FileIsEnding(h))
     {
      string rec=FileReadString(h);
      if(rec=="")
         continue;
      string f[];
      ushort delimiter=StringGetCharacter("|",0);
      if(StringSplit(rec,delimiter,f)!=2)
         continue;
      ulong ticket=(ulong)StringToInteger(f[0]);
      long valid_epoch=(long)StringToInteger(f[1]);
      if(ticket==0 || valid_epoch<=0)
         continue;
      if(!OrderSelect(ticket) || !guard_ok || !IsManagedOrder(guard.broker_symbol,guard.magic))
         continue;

      if((long)TimeGMT()<=valid_epoch)
        {
         keep+=rec+"\n";
         continue;
        }

      string message="";
      if(CancelManagedTicket(ticket,guard,message))
        {
         Acknowledge("expiry-"+(string)ticket,"OK","expired pending cancelled");
         Print("expired pending ",ticket," cancelled");
        }
      else
         keep+=rec+"\n";
     }
   FileClose(h);

   WriteSmallFile(PENDING_META_FILE,keep);
  }

bool CloseManagedTicket(const ulong ticket,const GuardConfig &guard,string &message)
  {
   string symbol=guard.broker_symbol;
   if(ticket==0 || !PositionSelectByTicket(ticket))
     {
      message="target position not found";
      return false;
     }
   if(!IsManagedPosition(symbol,guard.magic))
     {
      message="target position is not managed by this bridge";
      return false;
     }

   MqlTick tick={};
   if(!SymbolInfoTick(symbol,tick))
     {
      message="no tick while closing";
      return false;
     }

   long position_type=PositionGetInteger(POSITION_TYPE);
   double volume=PositionGetDouble(POSITION_VOLUME);
   ENUM_ORDER_TYPE type=(position_type==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   MqlTradeRequest request={};
   MqlTradeResult result={};
   request.action=TRADE_ACTION_DEAL;
   request.position=ticket;
   request.symbol=symbol;
   request.volume=volume;
   request.type=type;
   request.price=(type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   request.deviation=guard.deviation_points;
   request.magic=guard.magic;
   request.comment="cgpt-h1-close";
   request.type_time=ORDER_TIME_GTC;
   request.type_filling=FillingMode(symbol);
   return SendChecked(request,result,message);
  }

bool CloseAllManaged(const GuardConfig &guard,string &message)
  {
   bool found=false;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(guard.broker_symbol,guard.magic))
         continue;
      found=true;
      string one="";
      if(!CloseManagedTicket(ticket,guard,one))
        {
         message=one;
         return false;
        }
     }
   message=found ? "all managed positions closed" : "no managed positions";
   return true;
  }

bool ModifyManaged(const BridgeSignal &signal,const GuardConfig &guard,string &message)
  {
   ulong ticket=signal.target_ticket;
   string symbol=guard.broker_symbol;
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(ticket==0)
     {
      message="MODIFY requires target_ticket";
      return false;
     }

   if(PositionSelectByTicket(ticket))
     {
      if(!IsManagedPosition(symbol,guard.magic))
        {
         message="target position is not managed by this bridge";
         return false;
        }
      if(signal.has_entry && !signal.has_sl && !signal.has_tp)
        {
         message="entry cannot modify an open position";
         return false;
        }

      MqlTick tick={};
      if(!SymbolInfoTick(symbol,tick))
        {
         message="no tick while modifying position";
         return false;
        }

      long ptype=PositionGetInteger(POSITION_TYPE);
      bool is_buy=(ptype==POSITION_TYPE_BUY);
      double sl=signal.has_sl ? signal.sl : PositionGetDouble(POSITION_SL);
      double tp=signal.has_tp ? signal.tp : PositionGetDouble(POSITION_TP);
      if(sl<=0 || tp<=0)
        {
         message="managed positions must keep SL and TP";
         return false;
        }
      if(is_buy)
        {
         if(sl>=tick.bid || tp<=tick.bid)
           {
            message="invalid BUY SL/TP modification";
            return false;
           }
        }
      else
        {
         if(sl<=tick.ask || tp>=tick.ask)
           {
            message="invalid SELL SL/TP modification";
            return false;
           }
        }

      ENUM_ORDER_TYPE direction=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double candidate=RiskAmountForTrade(symbol,direction,
                                          PositionGetDouble(POSITION_VOLUME),
                                          PositionGetDouble(POSITION_PRICE_OPEN),sl);
      if(equity<=0)
        {
         message="invalid account equity";
         return false;
        }
      double candidate_pct=100.0*candidate/equity;
      if(candidate_pct>guard.max_risk_pct+1e-8 || candidate_pct>ABS_MAX_RISK_PCT+1e-8)
        {
         message="modified position risk exceeds per-trade cap";
         return false;
        }
      if(!CheckAggregateRisk(guard,candidate,ticket,message))
         return false;

      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_SLTP;
      request.position=ticket;
      request.symbol=symbol;
      request.sl=NormalizeDouble(sl,digits);
      request.tp=NormalizeDouble(tp,digits);
      request.magic=guard.magic;
      return SendChecked(request,result,message);
     }

   if(OrderSelect(ticket))
     {
      if(!IsManagedOrder(symbol,guard.magic))
        {
         message="target pending order is not managed by this bridge";
         return false;
        }

      ENUM_ORDER_TYPE otype=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(otype!=ORDER_TYPE_BUY_STOP && otype!=ORDER_TYPE_SELL_STOP)
        {
         message="only managed BUY_STOP/SELL_STOP can be modified";
         return false;
        }
      bool is_buy=(otype==ORDER_TYPE_BUY_STOP);
      double entry=signal.has_entry ? signal.entry : OrderGetDouble(ORDER_PRICE_OPEN);
      double sl=signal.has_sl ? signal.sl : OrderGetDouble(ORDER_SL);
      double tp=signal.has_tp ? signal.tp : OrderGetDouble(ORDER_TP);
      if(entry<=0 || sl<=0 || tp<=0)
        {
         message="pending order must keep entry, SL and TP";
         return false;
        }

      MqlTick tick={};
      if(!CheckSpread(symbol,tick,message,guard))
         return false;
      if(is_buy && entry<=tick.ask)
        {
         message="BUY_STOP entry must remain above current ask";
         return false;
        }
      if(!is_buy && entry>=tick.bid)
        {
         message="SELL_STOP entry must remain below current bid";
         return false;
        }

      double rr=0.0;
      if(!ValidateGeometry(is_buy,entry,sl,tp,guard.min_rr,rr,message))
         return false;

      ENUM_ORDER_TYPE direction=is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double candidate=RiskAmountForTrade(symbol,direction,
                                          OrderGetDouble(ORDER_VOLUME_CURRENT),entry,sl);
      if(equity<=0)
        {
         message="invalid account equity";
         return false;
        }
      double candidate_pct=100.0*candidate/equity;
      if(candidate_pct>guard.max_risk_pct+1e-8 || candidate_pct>ABS_MAX_RISK_PCT+1e-8)
        {
         message="modified pending risk exceeds per-trade cap";
         return false;
        }
      if(!CheckAggregateRisk(guard,candidate,ticket,message))
         return false;

      int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      MqlTradeRequest request={};
      MqlTradeResult result={};
      request.action=TRADE_ACTION_MODIFY;
      request.order=ticket;
      request.price=NormalizeDouble(entry,digits);
      request.sl=NormalizeDouble(sl,digits);
      request.tp=NormalizeDouble(tp,digits);
      request.magic=guard.magic;
      request.type_time=(ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
      request.expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(request.type_time==ORDER_TIME_SPECIFIED)
         request.expiration=UtcEpochToBrokerTime(signal.valid_epoch);
      return SendChecked(request,result,message);
     }

   message="target ticket not found";
   return false;
  }

void WriteState()
  {
   GuardConfig guard={};
   string error="";
   if(!LoadGuard(guard,error))
      return;

   string symbol=guard.broker_symbol;
   SymbolSelect(symbol,true);
   MqlTick tick={};
   bool has_tick=SymbolInfoTick(symbol,tick);

   int connected=(int)TerminalInfoInteger(TERMINAL_CONNECTED);
   int demo=((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO) ? 1 : 0;
   int trade_allowed=(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) &&
                      MQLInfoInteger(MQL_TRADE_ALLOWED) &&
                      AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) ? 1 : 0;
   int hedging=IsHedgingAccount() ? 1 : 0;

   int pos_count=ManagedPositionCount(symbol,guard.magic);
   int order_count=ManagedOrderCount(symbol,guard.magic);
   int unmanaged_count=UnmanagedSymbolExposureCount(symbol,guard.magic);
   double aggregate_risk=ManagedRiskPct(guard);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);

   string bid=has_tick ? DoubleToString(tick.bid,8) : "";
   string ask=has_tick ? DoubleToString(tick.ask,8) : "";
   string content=
      "2|"+(string)((long)TimeGMT())+
      "|"+IntegerToString(connected)+
      "|"+IntegerToString(demo)+
      "|"+IntegerToString(trade_allowed)+
      "|"+IntegerToString(hedging)+
      "|"+symbol+
      "|"+bid+
      "|"+ask+
      "|"+IntegerToString(pos_count)+
      "|"+IntegerToString(order_count)+
      "|"+IntegerToString(unmanaged_count)+
      "|"+DoubleToString(aggregate_risk,4)+
      "|"+g_last_signal_id;

   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !IsManagedPosition(symbol,guard.magic))
         continue;
      long ptype=PositionGetInteger(POSITION_TYPE);
      string type=(ptype==POSITION_TYPE_BUY) ? "BUY" : "SELL";
      ENUM_ORDER_TYPE direction=(ptype==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double risk_amount=RiskAmountForTrade(symbol,direction,
                                            PositionGetDouble(POSITION_VOLUME),
                                            PositionGetDouble(POSITION_PRICE_OPEN),
                                            PositionGetDouble(POSITION_SL));
      double risk_pct=(equity>0 && risk_amount!=DBL_MAX) ? 100.0*risk_amount/equity : 999.0;
      content+="\nP|"+(string)ticket+
               "|"+type+
               "|"+DoubleToString(PositionGetDouble(POSITION_VOLUME),8)+
               "|"+DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),8)+
               "|"+DoubleToString(PositionGetDouble(POSITION_SL),8)+
               "|"+DoubleToString(PositionGetDouble(POSITION_TP),8)+
               "|"+DoubleToString(PositionGetDouble(POSITION_PROFIT),2)+
               "|"+DoubleToString(risk_pct,4)+
               "|"+SafeField(PositionGetString(POSITION_COMMENT));
     }

   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !IsManagedOrder(symbol,guard.magic))
         continue;
      ENUM_ORDER_TYPE otype=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE direction=DirectionForOrderType(otype);
      double risk_amount=RiskAmountForTrade(symbol,direction,
                                            OrderGetDouble(ORDER_VOLUME_CURRENT),
                                            OrderGetDouble(ORDER_PRICE_OPEN),
                                            OrderGetDouble(ORDER_SL));
      double risk_pct=(equity>0 && risk_amount!=DBL_MAX) ? 100.0*risk_amount/equity : 999.0;
      datetime expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      string expiration_utc=expiration>0 ? (string)BrokerTimeToUtcEpoch(expiration) : "";
      content+="\nO|"+(string)ticket+
               "|"+EnumToString(otype)+
               "|"+DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT),8)+
               "|"+DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN),8)+
               "|"+DoubleToString(OrderGetDouble(ORDER_SL),8)+
               "|"+DoubleToString(OrderGetDouble(ORDER_TP),8)+
               "|"+DoubleToString(risk_pct,4)+
               "|"+expiration_utc+
               "|"+SafeField(OrderGetString(ORDER_COMMENT));
     }

   datetime history_to=TimeCurrent();
   datetime history_from=history_to-(60*24*60*60);
   if(HistorySelect(history_from,history_to))
     {
      for(int i=HistoryDealsTotal()-1;i>=0;i--)
        {
         ulong deal_ticket=HistoryDealGetTicket(i);
         if(deal_ticket==0)
            continue;
         if(HistoryDealGetString(deal_ticket,DEAL_SYMBOL)!=symbol)
            continue;
         if((ulong)HistoryDealGetInteger(deal_ticket,DEAL_MAGIC)!=guard.magic)
            continue;

         ENUM_DEAL_ENTRY deal_entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket,DEAL_ENTRY);
         if(deal_entry!=DEAL_ENTRY_OUT && deal_entry!=DEAL_ENTRY_OUT_BY)
            continue;

         datetime deal_time=(datetime)HistoryDealGetInteger(deal_ticket,DEAL_TIME);
         content+="\nD|"+(string)deal_ticket+
                  "|"+(string)HistoryDealGetInteger(deal_ticket,DEAL_POSITION_ID)+
                  "|"+EnumToString((ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket,DEAL_TYPE))+
                  "|"+EnumToString((ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket,DEAL_REASON))+
                  "|"+DoubleToString(HistoryDealGetDouble(deal_ticket,DEAL_PRICE),8)+
                  "|"+DoubleToString(HistoryDealGetDouble(deal_ticket,DEAL_PROFIT),2)+
                  "|"+(string)BrokerTimeToUtcEpoch(deal_time);
         break;
        }
     }

   WriteSmallFile(STATE_FILE,content);
  }

void ProcessBridge()
  {
   BridgeSignal signal={};
   string error="";
   if(!LoadSignal(signal,error))
      return;
   if(signal.id==g_last_signal_id)
      return;

   if(!IsKnownAction(signal.action))
     {
      FinishSignal(signal.id,"BLOCKED","unknown action");
      return;
     }

   long now=(long)TimeGMT();
   if(signal.created_epoch>now+300)
     {
      FinishSignal(signal.id,"BLOCKED","signal created_at is in the future");
      return;
     }
   if(signal.valid_epoch<=0 || now>signal.valid_epoch)
     {
      FinishSignal(signal.id,"BLOCKED","signal expired");
      return;
     }

   if(signal.action=="NO_TRADE" || signal.action=="HOLD" || signal.action=="STATUS")
     {
      WriteState();
      FinishSignal(signal.id,"OK",signal.action+" acknowledged");
      return;
     }

   GuardConfig guard={};
   if(!LoadGuard(guard,error))
     {
      Print("guard unavailable: ",error);
      return;
     }
   if(!CheckAccountGuard(guard,error))
     {
      if(error=="terminal not connected" || error=="automated trading is disabled")
        {
         Print("waiting: ",error);
         return;
        }
      FinishSignal(signal.id,"BLOCKED",error);
      return;
     }

   string message="";
   bool ok=false;

   if(signal.action=="BUY" || signal.action=="SELL")
      ok=OpenMarket(signal,guard,message);
   else if(signal.action=="BUY_STOP" || signal.action=="SELL_STOP")
      ok=PlacePending(signal,guard,message);
   else if(signal.action=="CLOSE")
     {
      if(signal.target_ticket==0)
        {
         message="CLOSE requires target_ticket";
         ok=false;
        }
      else
         ok=CloseManagedTicket(signal.target_ticket,guard,message);
     }
   else if(signal.action=="CANCEL")
     {
      if(signal.target_ticket==0)
        {
         message="CANCEL requires target_ticket";
         ok=false;
        }
      else
         ok=CancelManagedTicket(signal.target_ticket,guard,message);
     }
   else if(signal.action=="MODIFY")
      ok=ModifyManaged(signal,guard,message);
   else if(signal.action=="CLOSE_ALL")
      ok=CloseAllManaged(guard,message);
   else if(signal.action=="CANCEL_ALL")
      ok=CancelAllManaged(guard,message);

   FinishSignal(signal.id,ok ? "OK" : "BLOCKED",message);
   WriteState();
  }
