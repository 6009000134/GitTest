USE [AuctusERP]
GO
/****** Object:  StoredProcedure [dbo].[sp_Auctus_CostAnalysis]    Script Date: 2018/6/27 9:31:56 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

--从销售角度和产出角度分别找出 毛利率=毛利/BOM无软件成本
ALTER  PROC [dbo].[sp_Auctus_CostAnalysis]
(
@Org bigint,
@DisplayName bigint--期间
)
AS
BEGIN

--SET @DisplayName='2017-09'
--根据会计期间获取查询时间区间
DECLARE @FromDate DATETIME,@ToDate DATETIME
SELECT @FromDate=c.FromDate,@ToDate=c.ToDate FROM dbo.Base_SOBAccountingPeriod a LEFT JOIN dbo.Base_SetofBooks b ON a.SetofBooks=b.ID 
LEFT JOIN dbo.Base_AccountingPeriod c ON a.AccountPeriod=c.ID
WHERE b.Org=@Org 
--AND c.DisplayName=@DisplayName 
AND c.ID=@DisplayName
DECLARE @SOBPeriod BIGINT
SELECT @SOBPeriod=a.ID FROM dbo.Base_SOBAccountingPeriod a LEFT JOIN dbo.Base_SetofBooks b ON a.SetofBooks=b.ID 
LEFT JOIN dbo.Base_AccountingPeriod c ON a.AccountPeriod=c.ID
WHERE b.Org=@Org 
AND c.ID=@DisplayName

--出货集 #tempSoCost
IF OBJECT_ID(N'tempdb.dbo.#tempSoCost',N'U') IS NULL
BEGIN
CREATE TABLE  #tempSoCost (ShipNo VARCHAR(50),ShipLineNo VARCHAR(50),ItemInfo_ItemID VARCHAR(50),ItemInfo_ItemCode VARCHAR(50),
ItemInfo_ItemName VARCHAR(50), QtyPriceAmount DECIMAL(18,2),OrderPrice DECIMAL(18,4),TotalNetMoney DECIMAL(18,4),
TotalMoneyTC DECIMAL(18,4),TaxRate DECIMAL(18,4),AC INT,DemandCode INT,ShipList VARCHAR(500),DemandList VARCHAR(500))
END 
ELSE
BEGIN
TRUNCATE TABLE #tempSoCost
END


--Insert Into  #tempSoCost
; 
WITH tempSoCost AS
(
	SELECT a.DocNo ShipNo,--出货单号
	b.DocLineNo ShipLineNo,--出货单行
	b.ItemInfo_ItemID,b.ItemInfo_ItemCode,b.ItemInfo_ItemName,--料品信息
	b.QtyPriceAmount,--计价数量
	b.OrderPrice/(1+b.TaxRate) OrderPrice,--未税单价
	b.TotalNetMoney*a.ACToFCExRate TotalNetMoney,--未税金额
	b.TotalMoneyTC,--税价合计
	b.TaxRate,--税率
	a.AC,
	b.DemandCode--需求分类号
	FROM dbo.SM_Ship a LEFT JOIN dbo.SM_ShipLine b ON a.ID=b.Ship
	WHERE a.ShipConfirmDate BETWEEN @FromDate AND @ToDate AND a.Status=3  AND b.status=3  AND a.Org=@Org
	AND (b.ItemInfo_ItemCode LIKE '1%' OR b.ItemInfo_ItemCode LIKE '2%')
	--AND b.ItemInfo_ItemCode='101010022'
),
tempSoCostResult AS
(
	SELECT *,(SELECT b.ShipNo+',' FROM tempSoCost b WHERE b.ItemInfo_ItemCode=a.ItemInfo_ItemCode FOR XML PATH(''))shipList,
	(SELECT CAST(b.DemandCode AS VARCHAR(20))+',' FROM tempSoCost b WHERE b.ItemInfo_ItemCode=a.ItemInfo_ItemCode FOR XML PATH(''))demandList FROM tempSoCost a
)
INSERT INTO #tempSoCost
        SELECT * FROM tempSoCostResult


	--SELECT b.*,(SELECT CAST(a.DemandCode AS VARCHAR(20))+',' FROM #tempSoCost a WHERE a.ItemInfo_ItemCode=b.ItemInfo_ItemCode FOR XML PATH('')) FROM #tempSoCost b 
	--标准生产材料费取最新版本
--标准材料物料集合
IF object_id(N'tempdb.dbo.#tempItem',N'U') is NULL
begin
CREATE TABLE #tempItem(MasterBom BIGINT,MasterCode varchar(50),ThisUsageQty decimal(18,8),PID BIGINT,MID BIGINT,Code VARCHAR(50))
END
ELSE
BEGIN
TRUNCATE TABLE #tempItem
END
--标准材料结果集
IF object_id(N'tempdb.dbo.#tempMaterialResult',N'U') is NULL
begin
CREATE TABLE #tempMaterialResult (MasterBom BIGINT,MasterCode BIGINT,Price DECIMAL(18,8))
END
ELSE
BEGIN
TRUNCATE TABLE #tempMaterialResult
END 
INSERT INTO #tempItem SELECT t.id,t.ItemInfo_ItemCode,t1.ThisUsageQty,t1.PID,t1.MID,t1.Code FROM (
SELECT a.ItemInfo_ItemCode MasterCode,b.id,a.ItemInfo_ItemCode ,
ROW_NUMBER()OVER(PARTITION BY a.ItemInfo_ItemCode ORDER BY b.BOMVersion DESC) rn 
FROM #tempSoCost a LEFT JOIN dbo.CBO_ItemMaster c ON a.ItemInfo_ItemCode=c.Code LEFT JOIN dbo.CBO_BOMMaster b ON c.ID=b.ItemMaster
WHERE b.Org=@Org AND b.BOMType=0 AND b.AlternateType=0 ) t LEFT JOIN dbo.Auctus_NewestBom t1 ON t.ID=t1.MasterBom
 WHERE t.rn=1 AND  t1.Code NOT LIKE 'S%' AND t1.Code NOT LIKE '401%' AND t1.Code NOT LIKE '403%'
 --GROUP BY t.id
 --SELECT * FROM dbo.CBO_BOMMaster  WHERE ItemMaster=1001708090021645

 ;
 WITH PPRData AS 
 (
 SELECT * FROM (SELECT   a1.ItemInfo_ItemID,
						CASE WHEN a2.currency=1 AND  a2.IsIncludeTax = 1 						THEN ISNULL(Price, 0)/1.16
						WHEN a2.Currency=1 AND a2.IsIncludeTax=0						THEN ISNULL(Price, 0)
						WHEN a2.Currency!=1 AND a2.IsIncludeTax=1						THEN ISNULL(Price, 0) * dbo.fn_CustGetCurrentRate(a2.Currency, 1, GETDATE(), 2)/1.16
						ELSE ISNULL(Price, 0) * dbo.fn_CustGetCurrentRate(a2.Currency, 1, GETDATE(), 2) END Price,
						ROW_NUMBER()OVER(PARTITION BY a1.ItemInfo_ItemID ORDER BY a1.FromDate DESC) AS rowNum					--倒序排生效日
				FROM    PPR_PurPriceLine a1 RIGHT JOIN #tempItem c ON a1.ItemInfo_ItemID=c.MID
						INNER JOIN PPR_PurPriceList a2 ON a1.PurPriceList = a2.ID AND a2.Status = 2 AND a2.Cancel_Canceled = 0 AND a1.Active = 1
				WHERE   NOT EXISTS ( SELECT 1 FROM CBO_Supplier WHERE DescFlexField_PrivateDescSeg3 = 'OT01' AND a2.Supplier = ID ) AND 
						a2.Org = @Org
						--a2.Org=1001708020135665
						AND a1.FromDate <= GETDATE())
						t WHERE t.rowNum=1
 ),
 MInfo AS
 (
 SELECT a.MasterBom,a.MasterCode,a.PID,a.ThisUsageQty,a.MID,a.Code,ISNULL(c.StandardPrice,ISNULL(d.Price,0))StandardPrice
 --,c.StandardPrice StandardPrice2,d.Price--测试价格来源
 FROM #tempItem a LEFT JOIN #tempItem b ON a.MID=b.PID AND a.MasterBom=b.MasterBom
 LEFT JOIN dbo.Auctus_ItemStandardPrice c ON a.MID=c.ItemId 
 AND c.LogTime=dbo.fun_Auctus_GetInventoryDate(@ToDate)
 --AND c.LogTime='2018-05-01'
 LEFT JOIN PPRData d ON a.MID=d.ItemInfo_ItemID
 WHERE b.PID IS NULL 
 )
 --SELECT * FROM MInfo
 INSERT INTO #tempMaterialResult
 SELECT a.MasterBom,a.MasterCode,SUM(a.ThisUsageQty*a.StandardPrice)Price FROM MInfo a
 GROUP BY a.MasterBom,a.MasterCode

 --SELECT * FROM #tempItem WHERE MasterCode='202020475'--材料明细
 --SELECT * FROM #tempSoCost WHERE ItemInfo_ItemCode='202020408'--销售单
-- SELECT * FROM dbo.Auctus_NewestBom WHERE MasterBom=1001802280036796
-- SELECT * FROM #tempMaterialResult WHERE MasterCode='202020475'--材料费汇总
/*
 SELECT a.MasterBom,a.MasterCode,a.PID,a.ThisUsageQty,a.MID,a.Code,ISNULL(c.StandardPrice,ISNULL(d.Price,0))StandardPrice
 --,c.StandardPrice StandardPrice2,d.Price--测试价格来源
 FROM #tempItem a LEFT JOIN #tempItem b ON a.MID=b.PID AND a.MasterBom=b.MasterBom
 LEFT JOIN dbo.Auctus_ItemStandardPrice c ON a.MID=c.ItemId AND c.LogTime=''
 LEFT JOIN PPRData d ON a.MID=d.ItemInfo_ItemID
 WHERE b.PID IS NULL
*/
 --TODO:
--标准材料取工单版本
--End TODO

--生产订单集 #MOData
IF OBJECT_ID(N'tempdb.dbo.#MOData',N'U') IS NULL
BEGIN
CREATE TABLE #MOData (MOID BIGINT,DocNo VARCHAR(50),BOMMaster BIGINT,ItemMaster BIGINT,Code VARCHAR(50),BomVersion BIGINT,BomVersionCode VARCHAR(50)
	,DemandCode INT,ActualCompleteDate DATE,RN INT,DocList VARCHAR(5000))
END
ELSE
BEGIN
TRUNCATE TABLE #MOData
END 

	--Insert #MOData	
	;
	WITH MOMO AS
    (
	SELECT * FROM (
	SELECT a.ID MoID,a.docno,b.ID BOMMaster,a.ItemMaster,c.Code,b.BomVersion,b.BOMVersionCode,a.DemandCode,
	dbo.fun_Auctus_GetInventoryDate(a.ActualCompleteDate)ActualCompleteDate,
	ROW_NUMBER()OVER(PARTITION BY a.DocNo,a.ItemMaster ORDER BY b.BOMVersion DESC ) RN
	FROM dbo.MO_MO a LEFT JOIN dbo.CBO_BOMMaster b ON a.ItemMaster=b.ItemMaster LEFT JOIN dbo.CBO_ItemMaster c ON b.ItemMaster=c.ID
	WHERE a.DemandCode IN (SELECT DISTINCT DemandCode FROM #tempSoCost)
	) T
	WHERE T.RN=1 	
	),
	MO AS
    (
	SELECT a.*,(SELECT b.DocNo+',' FROM MOMO b WHERE b.Code=a.Code FOR XML PATH(''))aa  FROM MOMO a
	)
INSERT INTO #MOData
	SELECT * FROM MO ORDER BY MO.DemandCode


----软件结果集  @SoftResult
if object_id(N'tempdb.dbo.#SoftResult',N'U') is NULL
BEGIN
CREATE TABLE  #SoftResult (MOID BIGINT,ActualCompleteDate DATE,MasterBom BIGINT,PID BIGINT,MID BIGINT,ThisUsageQty DECIMAL(18,8))
END
ELSE
BEGIN 
TRUNCATE TABLE #SoftResult
END 
INSERT INTO #SoftResult
	SELECT b.MOID,b.ActualCompleteDate,a.MasterBom,a.PID,a.MID,a.ThisUsageQty
	FROM dbo.Auctus_NewestBom a RIGHT JOIN #MOData b ON a.MasterBom=b.BOMMaster
	WHERE  (PATINDEX('401%',a.Code)>0 OR PATINDEX('403%',a.Code)>0 OR PATINDEX('S%',a.Code)>0 )	
	

;
WITH SOResult AS--出货订单结果集
(
SELECT a.ItemInfo_ItemID,a.ItemInfo_ItemCode,a.ItemInfo_ItemName,--料品信息
SUM(a.TotalNetMoney)TotalSales,--出货总未税金额
SUM(a.QtyPriceAmount) QtyPriceAmount	--出货总数量
,MIN(a.ShipList)ShipList,MIN(a.DemandList)DemandList
FROM #tempSoCost a
GROUP BY a.ItemInfo_ItemID,a.ItemInfo_ItemCode,a.ItemInfo_ItemName
),
SoftR AS
(
	SELECT a.* FROM #SoftResult a LEFT JOIN #SoftResult b ON a.MID=b.PID AND a.MOID=b.MOID
	WHERE b.PID IS NULL
),
SoftPrice AS
(
SELECT a.MOID,SUM(a.ThisUsageQty*ISNULL(b.Price,0)) StandardPrice FROM SoftR a LEFT JOIN dbo.Auctus_ItemStandardPrice b ON a.MID=b.ItemId AND a.ActualCompleteDate=b.LogTime
GROUP BY a.MOID
),
RcvDate AS	--完工时间区间
(
	SELECT a.MOID,a.DocNo,ISNULL(MIN(d.FromDate),'9999-12-31') rcvFrom,ISNULL(MAX(d.ToDate),'9999-12-31')  rcvTo
	FROM #MOData a LEFT JOIN dbo.CA_CostQuery b ON a.MOID=b.MO 
	LEFT JOIN dbo.Base_SOBAccountingPeriod c ON b.SOBPeriod=c.ID 
	LEFT JOIN dbo.Base_AccountingPeriod d ON c.AccountPeriod=d.ID
	GROUP BY a.MOID,a.DocNo
),
MOResult AS 
(
SELECT a.MoID,a.BOMMaster,a.ItemMaster,a.BOMVersion,a.BOMVersionCode,e.Code,e.Name,'标准软件费' CostElementType, 
SUM(ISNULL(b.StandardPrice,0)*ISNULL(c.CompleteQty,0)) CurrentCost ,SUM(c.CompleteQty) CompleteQty
,MIN(a.DocList)DocList
FROM #MOData a LEFT JOIN SoftPrice b ON a.MoID=b.MoID
LEFT JOIN dbo.MO_CompleteRpt c ON a.MoID=c.MO LEFT JOIN mo_mo d ON a.MoID=d.ID 
LEFT JOIN dbo.CBO_ItemMaster e ON a.ItemMaster=e.ID LEFT JOIN RcvDate f ON a.MOID=f.MoID
WHERE c.ActualRcvTime BETWEEN f.rcvFrom AND f.rcvTo
GROUP BY a.MoID,a.BOMMaster,a.ItemMaster,a.BOMVersion,a.BOMVersionCode,e.Code,e.Name
),
CostQuery AS--实际成本，通过需求分类号关联订单再关联到生产成本计算表
(
SELECT  a.MoID,a.BOMMaster,a.BOMVersion,a.BOMVersionCode,a.ItemMaster,d.Code,d.Name,--料品信息
--e1.Name CostElement,--成本要素
f1.Name CostElementType,--成要素类型
ISNULL(SUM(ISNULL(c.ReceiptCost_CurrentCost,0)),0)+ISNULL(SUM(ISNULL(c.RealCost_PriorCost,0)),0) CurrentCost
,0 CompleteQty
,MIN(a.DocList)DocList
FROM #MOData a LEFT JOIN dbo.CA_CostQuery c ON a.MoID=c.MO LEFT JOIN dbo.CBO_ItemMaster d ON a.ItemMaster=d.ID
LEFT JOIN dbo.CBO_CostElement e ON c.CostElement=e.ID LEFT JOIN dbo.CBO_CostElement_Trl e1 ON e.ID=e1.ID AND e1.SysMLFlag='zh-CN'
LEFT JOIN dbo.CBO_CostElement f ON e.ParentNode=f.ID LEFT JOIN dbo.CBO_CostElement_Trl f1 ON f.ID=f1.ID AND f1.SysMLFlag='zh-CN'
WHERE c.ReceiptCost_CurrentCost IS NOT NULL 
--AND c.SOBPeriod=@SOBPeriod--将没有实际成本数据的记录剔除
GROUP BY a.MoID,a.BOMMaster,a.BOMVersion,a.BOMVersionCode,a.ItemMaster,d.Code,d.Name,f1.Name
UNION ALL
SELECT b.MoID,b.BOMMaster,b.BOMVersion,b.BOMVersionCode,b.ItemMaster,b.Code
,b.Name,b.CostElementType,ISNULL(b.CurrentCost ,0)CurrentCost
,b.CompleteQty
,b.DocList
FROM MOResult b
),
Result AS
(
SELECT 
a.BOMMaster,a.BomVersion,a.BOMVersionCode,a.ItemMaster,a.Code,a.Name,ISNULL(a.MaterialCost,0)MaterialCost
,ISNULL(b.ManMadeCost,0)ManMadeCost,ISNULL(c.ProductCost,0)ProductCost,ISNULL(d.OutCost,0)OutCost,ISNULL(e.MachineCost,0)MachineCost,ISNULL(f.SoftCost,0) SoftCost
,f.CompleteQty
,a.DocList
FROM (SELECT t.BOMMaster,t.BomVersion,t.BOMVersionCode,t.ItemMaster,t.Code,t.Name,SUM(t.CurrentCost) MaterialCost,MIN(t.DocList)DocList
		FROM CostQuery t WHERE t.CostElementType='直接材料费' GROUP BY t.BOMMaster,t.BomVersion,t.BOMVersionCode,t.ItemMaster,t.Code,t.Name) a
		LEFT JOIN (SELECT CostQuery.BOMMaster,SUM(CurrentCost)ManMadeCost FROM CostQuery WHERE CostElementType='人工费' GROUP BY BOMMaster) b ON a.BOMMaster=b.BOMMaster
		LEFT JOIN (SELECT CostQuery.BOMMaster,SUM(CurrentCost)ProductCost FROM CostQuery WHERE CostElementType='制造费' GROUP BY BOMMaster) c ON a.BOMMaster=c.BOMMaster
		LEFT JOIN (SELECT CostQuery.BOMMaster,SUM(CurrentCost)OutCost FROM CostQuery WHERE CostElementType='外协费' GROUP BY BOMMaster) d ON a.BOMMaster=d.BOMMaster
		LEFT JOIN (SELECT CostQuery.BOMMaster,SUM(CurrentCost)MachineCost FROM CostQuery WHERE CostElementType='机器费' GROUP BY BOMMaster) e ON a.BOMMaster=e.BOMMaster
		LEFT JOIN (SELECT CostQuery.BOMMaster,SUM(CurrentCost)SoftCost,SUM(CompleteQty)CompleteQty FROM CostQuery WHERE CostElementType='标准软件费' GROUP BY BOMMaster) f ON a.BOMMaster=f.BOMMaster
),
Result2 AS 
(
SELECT a.ItemMaster,a.Code,a.Name,SUM(a.MaterialCost+a.OutCost-a.SoftCost) MCost,SUM(a.MaterialCost+a.OutCost+a.ManMadeCost-a.SoftCost) MMCost,
SUM(a.MaterialCost+a.OutCost+a.ManMadeCost+a.ProductCost-a.SoftCost) MMPCost
,ISNULL(SUM(ISNULL(a.CompleteQty,0)),0)CompleteQty,SUM(a.SoftCost)SoftCost
,MIN(a.DocList)DocList
FROM Result a
GROUP BY a.ItemMaster,a.Code,a.Name
),
Result3 AS
(
SELECT a.ItemInfo_ItemID,a.ItemInfo_ItemCode,a.ItemInfo_ItemName,a.QtyPriceAmount,
dbo.fun_Auctus_GetProductType(d.DescFlexField_PrivateDescSeg9,GETDATE(),'zh-CN')产品类型,
CONVERT(DECIMAL(18,2),a.TotalSales)TotalSales,c.Price*a.QtyPriceAmount 标准材料费,
CASE d.DescFlexField_PrivateDescSeg11 WHEN '' THEN NULL ELSE  40*CONVERT(DECIMAL(18,2),d.DescFlexField_PrivateDescSeg11) END 标准人工制费,
CASE b.CompleteQty WHEN 0 THEN 0 ELSE CONVERT(DECIMAL(18,2),ISNULL(b.MCost,0)/b.CompleteQty*a.QtyPriceAmount) END MCost,
CASE b.CompleteQty WHEN 0 THEN 0 ELSE CONVERT(DECIMAL(18,2),ISNULL(b.MMCost,0)/b.CompleteQty*a.QtyPriceAmount) END MMCost,
CASE b.CompleteQty WHEN 0 THEN 0 ELSE CONVERT(DECIMAL(18,2),ISNULL(b.MMPCost,0)/b.CompleteQty*a.QtyPriceAmount) END MMPCost,
CASE  WHEN a.TotalSales=0 OR b.CompleteQty=0 OR a.QtyPriceAmount=0 THEN NULL ELSE CONVERT(DECIMAL(18,4),(a.TotalSales-ISNULL(b.MCost,0)/b.CompleteQty*a.QtyPriceAmount)/a.TotalSales)END  MRate,
CASE  WHEN a.TotalSales=0 OR b.CompleteQty=0 OR a.QtyPriceAmount=0 THEN NULL ELSE CONVERT(DECIMAL(18,4),(a.TotalSales-ISNULL(b.MMCost,0)/b.CompleteQty*a.QtyPriceAmount)/a.TotalSales ) END MMRate,
CASE  WHEN a.TotalSales=0 OR b.CompleteQty=0 OR a.QtyPriceAmount=0 THEN NULL ELSE CONVERT(DECIMAL(18,4),(a.TotalSales-ISNULL(b.MMPCost,0)/b.CompleteQty*a.QtyPriceAmount)/a.TotalSales)END MMPRate
,b.CompleteQty,CASE b.CompleteQty WHEN 0 THEN NULL ELSE b.SoftCost/b.CompleteQty*a.QtyPriceAmount END 标准软件费
,a.ShipList,a.DemandList
,b.DocList
FROM SOResult  a LEFT JOIN Result2 b ON a.ItemInfo_ItemID =b.ItemMaster
LEFT JOIN #tempMaterialResult c ON a.ItemInfo_ItemCode=c.MasterCode
LEFT JOIN CBO_ItemMaster d ON a.ItemInfo_ItemID=d.ID
)
SELECT * FROM Result3 a
ORDER BY a.MRate DESC


END
